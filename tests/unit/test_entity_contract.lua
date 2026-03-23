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


-- ================================================================ summary

io.write(('\n%d passed, %d failed\n'):format(pass_count, fail_count))
if fail_count > 0 then
  os.exit(1)
end
