#!/usr/bin/env lua5.1
--
-- Standalone unit tests for the entity contract:
-- type info discovery, access control nil-safety, deletion relation cleanup,
-- and lifecycle hook consistency.
--
-- Runs without the full Ophal bootstrap.  Requires seawolf from vendor.
--

-- ------------------------------------------------------------------ helpers

local pass_count, fail_count = 0, 0

local function assert_eq(label, got, expected)
  if got == expected then
    pass_count = pass_count + 1
  else
    fail_count = fail_count + 1
    io.stderr:write(('FAIL: %s: expected %s, got %s\n'):format(
      label, tostring(expected), tostring(got)))
  end
end

local function assert_match(label, text, pattern)
  if type(text) == 'string' and text:find(pattern) then
    pass_count = pass_count + 1
  else
    fail_count = fail_count + 1
    io.stderr:write(('FAIL: %s: pattern "%s" not found in:\n  %s\n'):format(
      label, pattern, tostring(text)))
  end
end

-- ------------------------------------------------------------------ setup

-- Load seawolf into globals (same as the framework does)
seawolf = require 'seawolf'
seawolf.__build('text', 'variable', 'contrib', 'fs')

-- DB query recorder
local db_log = {}
local function mock_db_query(sql, ...)
  db_log[#db_log + 1] = {sql = sql, params = {...}}
  local mock_rs = {}
  function mock_rs:fetch() return nil end
  function mock_rs:rows()
    return function() return nil end
  end
  return mock_rs
end

-- Hook call recorder
local hook_log = {}

local function reset_all()
  db_log = {}
  hook_log = {}

  -- Clear cached module entries from package.loaded
  for k in pairs(package.loaded) do
    if k:find('^modules%.') or k:find('^ophal%.modules%.') then
      package.loaded[k] = nil
    end
  end

  settings = {
    modules = {},
    entity = {
      testchild = {
        parents = {'parent_alpha', 'parent_beta'},
      },
    },
  }
  ophal = { modules = {} }

  -- Stub globals needed by entity module at load time
  t = function(s) return s end
  l = function(text) return text end
  theme = setmetatable({}, {__call = function() return '' end})
  route_arg = function() return nil end
  header = function() end
  page_set_title = function() end
  go_to = function() end
  _GET = {}
  db_query = mock_db_query
  db_last_insert_id = function() return 1 end

  -- Load module system (provides module_invoke_all, module_list, etc.)
  dofile('includes/module.lua')
end

local function setup_entity_env()
  reset_all()

  settings.modules = {
    entity = true,
    mockmod = true,
    baremod = true,
  }

  -- Wrap module_invoke_all to log hook calls before entity module captures it
  local real_mia = module_invoke_all
  module_invoke_all = function(hook, ...)
    hook_log[#hook_log + 1] = {hook = hook, args = {...}}
    return real_mia(hook, ...)
  end

  -- Load entity module (captures module_invoke_all, config, etc.)
  dofile('modules/entity/init.lua')

  -- Register mock module with full entity contract
  ophal.modules.mockmod = {
    entity_type_info = function()
      return {
        mockmod = {
          name = {'mock entity', plural = 'mock entities'},
          module = 'mockmod',
        },
      }
    end,
    load = function(id)
      return {id = id, type = 'mockmod', user_id = 1, title = 'Mock ' .. id}
    end,
    entity_access = function() return true end,
    route_page = function() return '' end,
    delete = function() return true end,
  }

  -- Register bare module (no entity_type_info, no entity_access, no route_page)
  ophal.modules.baremod = {
    load = function(id)
      return {id = id, type = 'baremod', user_id = 1}
    end,
  }

  -- Mock user module for entity_access
  ophal.modules.user = {
    current = function()
      return {id = 1, name = 'testuser'}
    end,
    access = function()
      return true
    end,
  }

  -- Initialize entity module (binds user_mod reference)
  ophal.modules.entity.init()
end


-- ================================================ ENTITY TYPE INFO TESTS

io.write('-- entity type info --\n')

setup_entity_env()

-- 1. Module with entity_type_info is discoverable
local info = ophal.modules.entity.get_entity_type_info('mockmod')
assert_eq('type_info_found', info ~= nil, true)
assert_eq('type_info_name', info.name[1], 'mock entity')
assert_eq('type_info_plural', info.name.plural, 'mock entities')
assert_eq('type_info_module', info.module, 'mockmod')

-- 2. Module without entity_type_info returns nil
local bare_info = ophal.modules.entity.get_entity_type_info('baremod')
assert_eq('type_info_nil_for_bare', bare_info, nil)

-- 3. Unknown type returns nil
local unknown_info = ophal.modules.entity.get_entity_type_info('nonexistent')
assert_eq('type_info_nil_for_unknown', unknown_info, nil)

-- 4. No-arg call returns full info table
local all_infos = ophal.modules.entity.get_entity_type_info()
assert_eq('all_infos_has_mockmod', all_infos.mockmod ~= nil, true)


-- ================================================ ENTITY ACCESS TESTS

io.write('-- entity access --\n')

setup_entity_env()

-- 5. entity_access returns false for unknown entity type (nil-safety)
local result5 = ophal.modules.entity.entity_access(
  {type = 'unknown_type'}, 'read')
assert_eq('access_nil_safety', result5, false)

-- 6. entity_access works for known type with admin permission
local result6 = ophal.modules.entity.entity_access(
  {type = 'mockmod', id = 1}, 'read')
assert_eq('access_known_type', result6, true)


-- ================================================ ENTITY DELETION TESTS

io.write('-- entity deletion --\n')

setup_entity_env()

-- 7. Relation cleanup uses actual parent type names, not array indices
db_log = {}
ophal.modules.entity.delete({type = 'testchild', id = 42})

assert_eq('delete_query_count', #db_log, 3)
assert_match('delete_main_table', db_log[1].sql, 'DELETE FROM testchild')
assert_match('delete_rel_alpha', db_log[2].sql, 'rel_testchild_parent_alpha')
assert_match('delete_rel_beta', db_log[3].sql, 'rel_testchild_parent_beta')

-- Verify no numeric parent names leaked through
for i = 2, #db_log do
  assert_eq('no_numeric_parent_' .. i,
    db_log[i].sql:find('rel_testchild_%d') == nil, true)
end

-- 8. entity_after_delete hook fires on successful delete
setup_entity_env()
hook_log = {}
ophal.modules.entity.delete({type = 'testchild', id = 99})

local found_hook = false
for _, entry in ipairs(hook_log) do
  if entry.hook == 'entity_after_delete' then
    found_hook = true
    assert_eq('after_delete_entity_type', entry.args[1].type, 'testchild')
    assert_eq('after_delete_entity_id', entry.args[1].id, 99)
    break
  end
end
assert_eq('after_delete_hook_fired', found_hook, true)

-- 9. Delete with no parents config does not crash
setup_entity_env()
db_log = {}
ophal.modules.entity.delete({type = 'orphantype', id = 7})
assert_eq('delete_no_parents_count', #db_log, 1)
assert_match('delete_no_parents_sql', db_log[1].sql, 'DELETE FROM orphantype')


-- ================================================ ROUTE INJECTION TESTS

io.write('-- route injection --\n')

setup_entity_env()

-- 10. route_alter injects default route when module has no explicit route
local items10 = {}
ophal.modules.entity.route_alter('mockmod', items10)
assert_eq('inject_route_exists', items10['mockmod'] ~= nil, true)
assert_eq('inject_page_cb_module', items10['mockmod'].page_callback.module, 'mockmod')
assert_eq('inject_access_cb_module', items10['mockmod'].access_callback.module, 'mockmod')

-- 11. route_alter does NOT inject when module already has a route
local items11 = {mockmod = {page_callback = 'existing_handler'}}
ophal.modules.entity.route_alter('mockmod', items11)
assert_eq('no_inject_existing', items11['mockmod'].page_callback, 'existing_handler')

-- 12. route_alter for bare module falls back to entity for callbacks
local items12 = {}
ophal.modules.entity.route_alter('baremod', items12)
assert_eq('bare_inject_exists', items12['baremod'] ~= nil, true)
assert_eq('bare_page_cb_fallback', items12['baremod'].page_callback.module, 'entity')
assert_eq('bare_access_cb_fallback', items12['baremod'].access_callback.module, 'entity')


-- ================================================ LIFECYCLE HOOK CONSISTENCY TESTS

io.write('-- lifecycle hook consistency --\n')

setup_entity_env()

-- 13. create fires entity_after_save
hook_log = {}
ophal.modules.mockmod.create = function(entity)
  module_invoke_all('entity_after_save', entity)
  return entity.id
end
ophal.modules.mockmod.create({id = 10, type = 'mockmod', title = 'New'})
local found_save = false
for _, entry in ipairs(hook_log) do
  if entry.hook == 'entity_after_save' then
    found_save = true
    assert_eq('create_hook_type', entry.args[1].type, 'mockmod')
    assert_eq('create_hook_id', entry.args[1].id, 10)
    break
  end
end
assert_eq('create_fires_after_save', found_save, true)

-- 14. update fires entity_after_save
hook_log = {}
ophal.modules.mockmod.update = function(entity)
  module_invoke_all('entity_after_save', entity)
end
ophal.modules.mockmod.update({id = 10, type = 'mockmod', title = 'Updated'})
local found_update_save = false
for _, entry in ipairs(hook_log) do
  if entry.hook == 'entity_after_save' then
    found_update_save = true
    assert_eq('update_hook_title', entry.args[1].title, 'Updated')
    break
  end
end
assert_eq('update_fires_after_save', found_update_save, true)

-- 15. delete fires entity_after_delete (via shared entity.delete)
setup_entity_env()
hook_log = {}
ophal.modules.entity.delete({type = 'orphantype', id = 50})
local found_del = false
for _, entry in ipairs(hook_log) do
  if entry.hook == 'entity_after_delete' then
    found_del = true
    assert_eq('delete_hook_id', entry.args[1].id, 50)
    break
  end
end
assert_eq('delete_fires_after_delete', found_del, true)


-- ================================================ ROUTE COEXISTENCE TESTS

io.write('-- route coexistence --\n')

setup_entity_env()

-- 16. Entity module route() returns all shared routes
local entity_routes = ophal.modules.entity.route()
assert_eq('shared_route_create', entity_routes['entity/create'] ~= nil, true)
assert_eq('shared_route_edit', entity_routes['entity/edit'] ~= nil, true)
assert_eq('shared_route_delete', entity_routes['entity/delete'] ~= nil, true)
assert_eq('shared_route_save', entity_routes['entity/save'] ~= nil, true)
assert_eq('shared_route_remove', entity_routes['entity/remove'] ~= nil, true)

-- 17. default_page delegates to module function when available
-- Note: entity module captures route_arg at file load time (line 4), so we must
-- set the global before dofile to affect the entity module's local reference.
local function setup_entity_env_with_route_arg(fn)
  reset_all()
  settings.modules = { entity = true, mockmod = true }
  route_arg = fn
  local real_mia = module_invoke_all
  module_invoke_all = function(hook, ...)
    hook_log[#hook_log + 1] = {hook = hook, args = {...}}
    return real_mia(hook, ...)
  end
  dofile('modules/entity/init.lua')
  ophal.modules.mockmod = {
    entity_type_info = function()
      return { mockmod = { name = {'mock', plural = 'mocks'}, module = 'mockmod' } }
    end,
    load = function(id) return {id = id, type = 'mockmod'} end,
  }
  ophal.modules.user = {
    current = function() return {id = 1} end,
    access = function() return true end,
  }
  ophal.modules.entity.init()
end

local dp_called = false
setup_entity_env_with_route_arg(function(n)
  if n == 2 then return 'mockmod' end
  return nil
end)
ophal.modules.mockmod.test_fn = function(a)
  dp_called = true
  return 'test_result_' .. a
end
local dp_result = ophal.modules.entity.default_page('test_fn', 'arg1')
assert_eq('default_page_delegates', dp_called, true)
assert_eq('default_page_result', dp_result, 'test_result_arg1')

-- 18. default_page returns 404 for missing function
local got_404 = false
setup_entity_env_with_route_arg(function(n)
  if n == 2 then return 'mockmod' end
  return nil
end)
header = function(k, v)
  if k == 'status' and v == 404 then got_404 = true end
end
ophal.modules.entity.default_page('nonexistent_fn')
assert_eq('default_page_404_missing_fn', got_404, true)

-- 19. default_page returns 404 for unknown module
got_404 = false
setup_entity_env_with_route_arg(function(n)
  if n == 2 then return 'no_such_module' end
  return nil
end)
header = function(k, v)
  if k == 'status' and v == 404 then got_404 = true end
end
ophal.modules.entity.default_page('load')
assert_eq('default_page_404_unknown_module', got_404, true)

-- 20. route_alter preserves legacy route when module has both own route and entity_type_info
setup_entity_env()
local items20 = {mockmod = {page_callback = 'legacy_handler', title = 'Legacy'}}
ophal.modules.entity.route_alter('mockmod', items20)
assert_eq('legacy_route_preserved', items20['mockmod'].page_callback, 'legacy_handler')
assert_eq('legacy_route_title', items20['mockmod'].title, 'Legacy')


-- ================================================ TAG ENTITY_ACCESS CONTRACT TESTS

io.write('-- tag entity_access --\n')

local function setup_tag_env()
  reset_all()

  settings.modules = {
    entity = true,
    tag = true,
  }
  settings.tag = {
    entities = {},
    items_per_page = 10,
  }
  settings.entity = settings.entity or {}
  settings.slash = nil

  -- Extra globals needed by tag module at load time
  env = {
    db_query = mock_db_query,
    db_limit = function() return ' LIMIT ?,?' end,
    db_last_insert_id = function() return 1 end,
  }
  add_css = function() end
  add_js = function() end
  pager = function() return {} end
  print_t = function() end
  request_get_body = function() return '{}' end
  format_date = function() return '' end
  page_not_found = function() return '' end
  url = function(s) return s end
  _SESSION = {user_id = 1}

  -- Wrap module_invoke_all to log hook calls
  local real_mia = module_invoke_all
  module_invoke_all = function(hook, ...)
    hook_log[#hook_log + 1] = {hook = hook, args = {...}}
    return real_mia(hook, ...)
  end

  -- Load entity module first
  dofile('modules/entity/init.lua')

  -- Load tag module
  dofile('modules/tag/init.lua')

  -- Mock user module
  local current_perms = {}
  ophal.modules.user = {
    current = function()
      return {id = 1, name = 'testuser'}
    end,
    access = function(perm)
      return current_perms[perm] or false
    end,
    load = function(id)
      return {id = id, name = 'user' .. id}
    end,
    _set_perms = function(perms) current_perms = perms end,
  }

  -- Initialize modules
  ophal.modules.tag.init()
  ophal.modules.entity.init()

  return ophal.modules.user
end

-- 21. tag entity_access: admin override grants all actions
local user_mock = setup_tag_env()
user_mock._set_perms({['administer tags'] = true})
assert_eq('tag_access_admin_read',
  ophal.modules.tag.entity_access({type = 'tag', user_id = 1}, 'read'), true)
assert_eq('tag_access_admin_create',
  ophal.modules.tag.entity_access({type = 'tag'}, 'create'), true)
assert_eq('tag_access_admin_delete',
  ophal.modules.tag.entity_access({type = 'tag', user_id = 99}, 'delete'), true)

-- 22. tag entity_access: create requires 'create tags' permission
user_mock = setup_tag_env()
user_mock._set_perms({['create tags'] = true})
assert_eq('tag_access_create_yes',
  ophal.modules.tag.entity_access({type = 'tag'}, 'create'), true)
user_mock._set_perms({})
assert_eq('tag_access_create_no',
  ophal.modules.tag.entity_access({type = 'tag'}, 'create'), false)

-- 23. tag entity_access: read requires 'access tags' permission
user_mock = setup_tag_env()
user_mock._set_perms({['access tags'] = true})
assert_eq('tag_access_read_yes',
  ophal.modules.tag.entity_access({type = 'tag', user_id = 1}, 'read'), true)

-- 24. tag entity_access: update requires permission AND ownership
user_mock = setup_tag_env()
user_mock._set_perms({['edit own tags'] = true})
assert_eq('tag_access_update_own',
  ophal.modules.tag.entity_access({type = 'tag', user_id = 1}, 'update'), true)
assert_eq('tag_access_update_other',
  ophal.modules.tag.entity_access({type = 'tag', user_id = 2}, 'update'), false)

-- 25. tag entity_access: delete requires permission AND ownership
user_mock = setup_tag_env()
user_mock._set_perms({['delete own tags'] = true})
assert_eq('tag_access_delete_own',
  ophal.modules.tag.entity_access({type = 'tag', user_id = 1}, 'delete'), true)
assert_eq('tag_access_delete_other',
  ophal.modules.tag.entity_access({type = 'tag', user_id = 2}, 'delete'), false)

-- 26. tag entity_access: unknown action returns false
user_mock = setup_tag_env()
user_mock._set_perms({})
assert_eq('tag_access_unknown_action',
  ophal.modules.tag.entity_access({type = 'tag', user_id = 1}, 'foobar'), false)

-- 27. tag entity_type_info includes module field
user_mock = setup_tag_env()
local tag_info = ophal.modules.tag.entity_type_info()
assert_eq('tag_info_has_module', tag_info.tag.module, 'tag')
assert_eq('tag_info_has_name', tag_info.tag.name[1], 'tag')
assert_eq('tag_info_has_plural', tag_info.tag.name.plural, 'tags')


-- ================================================ TAG PAGE HANDLER ACCESS TESTS

io.write('-- tag page handler access --\n')

-- Helper: set up tag env with controllable route_arg and header tracking.
-- Tag module captures route_arg and header at file scope, so these must be
-- set BEFORE dofile.
local function setup_tag_page_env(opts)
  reset_all()

  settings.modules = { entity = true, tag = true }
  settings.tag = { entities = {}, items_per_page = 10 }
  settings.entity = settings.entity or {}
  settings.slash = nil

  env = {
    db_query = mock_db_query,
    db_limit = function() return ' LIMIT ?,?' end,
    db_last_insert_id = function() return 1 end,
  }
  add_css = function() end
  add_js = function() end
  pager = function() return {} end
  print_t = function() end
  request_get_body = function() return '{}' end
  format_date = function() return '' end
  page_not_found = function() return '' end
  url = function(s) return s end
  _SESSION = {user_id = 1}

  -- Set route_arg and header BEFORE dofile so tag module captures them
  local ra_values = opts.route_arg_values or {}
  route_arg = function(n) return ra_values[n] end

  local header_log = {}
  header = function(k, v) header_log[#header_log + 1] = {k = k, v = v} end

  local real_mia = module_invoke_all
  module_invoke_all = function(hook, ...)
    hook_log[#hook_log + 1] = {hook = hook, args = {...}}
    return real_mia(hook, ...)
  end

  dofile('modules/entity/init.lua')
  dofile('modules/tag/init.lua')

  -- Mock user module (must be set before init() so user_mod captures it)
  local current_perms = {}
  ophal.modules.user = {
    current = function() return {id = 1, name = 'testuser'} end,
    access = function(perm) return current_perms[perm] or false end,
    load = function(id) return {id = id, name = 'user' .. id} end,
    is_logged_in = function() return true end,
    _set_perms = function(perms) current_perms = perms end,
  }

  ophal.modules.tag.init()
  ophal.modules.entity.init()

  -- Override tag.load to return a specific entity
  if opts.load_entity then
    ophal.modules.tag.load = function()
      return opts.load_entity
    end
  end

  return ophal.modules.user, header_log
end

-- 28. edit_page denies access to non-owner
local user28, hlog28 = setup_tag_page_env({
  route_arg_values = {[2] = '42'},
  load_entity = {id = 42, type = 'tag', name = 'Test Tag', user_id = 99},
})
user28._set_perms({['edit own tags'] = true})
local result28 = ophal.modules.tag.edit_page()
local got_401_28 = false
for _, h in ipairs(hlog28) do
  if h.k == 'status' and h.v == 401 then got_401_28 = true; break end
end
assert_eq('edit_page_denies_non_owner', got_401_28, true)
assert_eq('edit_page_denied_returns_empty', result28, '')

-- 29. edit_page allows owner
local user29, hlog29 = setup_tag_page_env({
  route_arg_values = {[2] = '42'},
  load_entity = {id = 42, type = 'tag', name = 'Test Tag', user_id = 1},
})
user29._set_perms({['edit own tags'] = true})
local result29 = ophal.modules.tag.edit_page()
local got_401_29 = false
for _, h in ipairs(hlog29) do
  if h.k == 'status' and h.v == 401 then got_401_29 = true; break end
end
assert_eq('edit_page_allows_owner', got_401_29, false)

-- 30. delete_page denies access to non-owner
local user30, hlog30 = setup_tag_page_env({
  route_arg_values = {[2] = '42'},
  load_entity = {id = 42, type = 'tag', name = 'Test Tag', user_id = 99},
})
user30._set_perms({['delete own tags'] = true})
local result30 = ophal.modules.tag.delete_page()
local got_401_30 = false
for _, h in ipairs(hlog30) do
  if h.k == 'status' and h.v == 401 then got_401_30 = true; break end
end
assert_eq('delete_page_denies_non_owner', got_401_30, true)
assert_eq('delete_page_denied_returns_empty', result30, '')

-- 31. delete_page allows owner
local user31, hlog31 = setup_tag_page_env({
  route_arg_values = {[2] = '42'},
  load_entity = {id = 42, type = 'tag', name = 'Test Tag', user_id = 1},
})
user31._set_perms({['delete own tags'] = true})
local result31 = ophal.modules.tag.delete_page()
local got_401_31 = false
for _, h in ipairs(hlog31) do
  if h.k == 'status' and h.v == 401 then got_401_31 = true; break end
end
assert_eq('delete_page_allows_owner', got_401_31, false)


-- ================================================================
io.write '\n-- tag route access gates --\n'
-- ================================================================

-- 32. tag_access: admin override passes any perm
local user32 = setup_tag_page_env({})
user32._set_perms({['administer tags'] = true})
assert_eq('tag_access_admin_create', ophal.modules.tag.tag_access('create tags'), true)

-- 33. tag_access: specific perm without admin
local user33 = setup_tag_page_env({})
user33._set_perms({['create tags'] = true})
assert_eq('tag_access_create_only', ophal.modules.tag.tag_access('create tags'), true)

-- 34. tag_access: denies without permission
local user34 = setup_tag_page_env({})
user34._set_perms({})
assert_eq('tag_access_denied', ophal.modules.tag.tag_access('create tags'), false)

-- 35. tag_access: service gate (nil perm) admits edit-own user
local user35 = setup_tag_page_env({})
user35._set_perms({['edit own tags'] = true})
assert_eq('tag_access_service_edit', ophal.modules.tag.tag_access(nil), true)

-- 36. tag_access: service gate denies user with no tag perms
local user36 = setup_tag_page_env({})
user36._set_perms({['access tags'] = true})  -- read-only, not a mutation perm
assert_eq('tag_access_service_denied', ophal.modules.tag.tag_access(nil), false)

-- 37. route definitions use tag_access, not bare user.access
local user37 = setup_tag_page_env({})
local routes37 = ophal.modules.tag.route()
assert_eq('route_tag_view_module', routes37.tag.access_callback.module, 'tag')
assert_eq('route_tag_add_module', routes37['tag/add'].access_callback.module, 'tag')
assert_eq('route_tag_edit_module', routes37['tag/edit'].access_callback.module, 'tag')
assert_eq('route_tag_delete_module', routes37['tag/delete'].access_callback.module, 'tag')
-- tag/service uses string callback (resolved to tag module by route_build_handler)
assert_eq('route_tag_service_is_string', routes37['tag/service'].access_callback, 'tag_access')
-- admin route stays on user module (no ownership logic needed)
assert_eq('route_admin_tags_module', routes37['admin/content/tags'].access_callback.module, 'user')


-- ================================================================ summary

io.write(('\n%d passed, %d failed\n'):format(pass_count, fail_count))
if fail_count > 0 then
  os.exit(1)
end
