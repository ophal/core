#!/usr/bin/env lua5.1
--
-- Standalone unit tests for module resolution order, route build order,
-- route conflict detection, and route freeze.
--
-- Runs without the full Ophal bootstrap.  Requires seawolf from vendor.
--

-- ------------------------------------------------------------------ helpers

local pass_count, fail_count = 0, 0
local stderr_capture = {}

local function assert_eq(label, got, expected)
  if got == expected then
    pass_count = pass_count + 1
  else
    fail_count = fail_count + 1
    io.stderr:write(('FAIL: %s: expected %s, got %s\n'):format(
      label, tostring(expected), tostring(got)))
  end
end

local function assert_list_eq(label, got, expected)
  local ok = true
  if #got ~= #expected then
    ok = false
  else
    for i = 1, #got do
      if got[i] ~= expected[i] then ok = false; break end
    end
  end
  if ok then
    pass_count = pass_count + 1
  else
    fail_count = fail_count + 1
    local function dump(t)
      local parts = {}
      for i = 1, #t do parts[i] = tostring(t[i]) end
      return '{' .. table.concat(parts, ', ') .. '}'
    end
    io.stderr:write(('FAIL: %s:\n  expected %s\n       got %s\n'):format(
      label, dump(expected), dump(got)))
  end
end

local function assert_match(label, text, pattern)
  if text:find(pattern) then
    pass_count = pass_count + 1
  else
    fail_count = fail_count + 1
    io.stderr:write(('FAIL: %s: pattern "%s" not found in:\n  %s\n'):format(
      label, pattern, text))
  end
end

local function assert_error(label, fn)
  local ok, err = pcall(fn)
  if not ok then
    pass_count = pass_count + 1
  else
    fail_count = fail_count + 1
    io.stderr:write(('FAIL: %s: expected error, but call succeeded\n'):format(label))
  end
end

-- Capture io.stderr:write calls by replacing io.stderr with a mock
local real_stderr = io.stderr
local mock_stderr = {}
mock_stderr.__index = mock_stderr
function mock_stderr:write(s)
  stderr_capture[#stderr_capture + 1] = s
  return self
end
setmetatable(mock_stderr, mock_stderr)

local function start_capture()
  stderr_capture = {}
  io.stderr = mock_stderr
end
local function stop_capture()
  io.stderr = real_stderr
  return table.concat(stderr_capture)
end

-- Reset global state between test groups so module_list() cache is cleared
local function reset_globals()
  -- Wipe any previous module_list / resolve caches by re-dofile
  settings = { modules = {} }
  ophal = { modules = {} }

  -- Clear any mocked info.lua entries from package.loaded
  for k in pairs(package.loaded) do
    if k:find('^modules%.') then
      package.loaded[k] = nil
    end
  end

  dofile('includes/module.lua')
end

-- ------------------------------------------------------------------ setup

-- Load seawolf into globals (same as the framework does)
seawolf = require 'seawolf'
seawolf.__build('text', 'variable', 'contrib', 'fs')

-- Initial load
reset_globals()

-- ================================================ MODULE ORDERING TESTS

io.write('-- module ordering --\n')

-- 1. Weight + name alphabetical (all weight 1)
reset_globals()
settings.modules = { user = true, content = true, tag = true, menu = true }
assert_list_eq('all_weight_1_alpha',
  module_list(),
  {'system', 'content', 'menu', 'tag', 'user'})

-- 2. Explicit weights
reset_globals()
settings.modules = { user = 5, content = true, tag = 3 }
assert_list_eq('explicit_weights',
  module_list(),
  {'system', 'content', 'tag', 'user'})

-- 3. Disabled modules skipped (break bug regression)
reset_globals()
settings.modules = { alpha = true, bravo = false, charlie = true }
local list3 = module_list()
-- Both alpha and charlie must appear regardless of pairs() order
assert_eq('disabled_skip_count', #list3, 3)
-- system first
assert_eq('disabled_skip_system', list3[1], 'system')
-- alpha and charlie present (order: alphabetical at weight 1)
assert_list_eq('disabled_skip_order', list3, {'system', 'alpha', 'charlie'})

-- 4. Repeated runs produce same reference (cached)
reset_globals()
settings.modules = { a = true, b = true }
local r1 = module_list()
local r2 = module_list()
assert_eq('cache_identity', r1, r2)
assert_list_eq('cache_content', r1, {'system', 'a', 'b'})

-- 5. Legacy module (no info.lua) synthesizes metadata
reset_globals()
settings.modules = { mymod = 3 }
local info = module_load_info('mymod')
assert_eq('synth_name', info.name, 'mymod')
assert_eq('synth_weight', info.weight, 3)
assert_eq('synth_deps_empty', #info.dependencies, 0)

-- 6. Legacy module with weight=true gets weight 1
reset_globals()
settings.modules = { mymod = true }
local info6 = module_load_info('mymod')
assert_eq('synth_weight_true', info6.weight, 1)

-- 7. Dependency ordering via mocked info.lua
reset_globals()
settings.modules = { alpha = 5, beta = 1 }
-- beta depends on alpha, so alpha must come first despite higher weight
package.loaded['modules.alpha.info'] = {
  name = 'alpha', dependencies = {}, weight = 5,
}
package.loaded['modules.beta.info'] = {
  name = 'beta', dependencies = {'alpha'}, weight = 1,
}
dofile('includes/module.lua')
assert_list_eq('dep_order', module_list(), {'system', 'alpha', 'beta'})

-- 8. Dependency on absent module silently ignored
reset_globals()
settings.modules = { alpha = true }
package.loaded['modules.alpha.info'] = {
  name = 'alpha', dependencies = {'nonexistent'}, weight = 1,
}
dofile('includes/module.lua')
assert_list_eq('dep_absent_ignored', module_list(), {'system', 'alpha'})

-- 9. Weight tie-break within same dependency group
reset_globals()
settings.modules = { charlie = true, alpha = true, bravo = true }
assert_list_eq('tiebreak_alpha',
  module_list(),
  {'system', 'alpha', 'bravo', 'charlie'})

-- 10. Mixed weights with dependencies
reset_globals()
settings.modules = { db = 2, auth = 3, ui = 1 }
-- auth depends on db; ui has no deps
package.loaded['modules.db.info'] = {
  name = 'db', dependencies = {}, weight = 2,
}
package.loaded['modules.auth.info'] = {
  name = 'auth', dependencies = {'db'}, weight = 3,
}
package.loaded['modules.ui.info'] = {
  name = 'ui', dependencies = {}, weight = 1,
}
dofile('includes/module.lua')
-- ui (w=1) first, then db (w=2), then auth (w=3, depends on db)
assert_list_eq('mixed_weight_deps',
  module_list(),
  {'system', 'ui', 'db', 'auth'})

-- 11. Cycle detection fallback
reset_globals()
settings.modules = { a = 1, b = 1 }
package.loaded['modules.a.info'] = {
  name = 'a', dependencies = {'b'}, weight = 1,
}
package.loaded['modules.b.info'] = {
  name = 'b', dependencies = {'a'}, weight = 1,
}
dofile('includes/module.lua')
start_capture()
local cycle_list = module_list()
local cycle_stderr = stop_capture()
-- system first, then the cycled modules appended as fallback
assert_eq('cycle_has_system', cycle_list[1], 'system')
assert_eq('cycle_total', #cycle_list, 3)
assert_match('cycle_warning', cycle_stderr, 'dependency cycle')


-- ================================================ ROUTE ORDERING TESTS

io.write('-- route ordering --\n')

-- Load route.lua needs some stubs
local function setup_route_env()
  reset_globals()

  -- Stubs required by route.lua top-level code
  base = ''
  _GET = {}

  -- route.lua references these globals
  ophal.routes = nil
  ophal.aliases = { source = {}, alias = {} }
  ophal.redirects = { source = {}, target = {} }
  ophal.route_aliases = {}
  ophal.route_redirects = {}
  route_set_title = function() end

  -- Stub functions that route.lua calls
  if not url then
    url = function(path) return '/' .. (path or '') end
  end
  if not l then
    l = function(path, text) return text or path end
  end
  if not t then
    t = function(s) return s end
  end
  if not table_shift then
    table_shift = function(t)
      local rest = {}
      for i = 2, #t do rest[#rest + 1] = t[i] end
      return rest
    end
  end
  if not request_path then
    request_path = function() return '' end
  end
end

-- 12. Deterministic route build order
setup_route_env()
settings.modules = { alpha = 1, beta = 2 }
dofile('includes/module.lua')

-- Register mock modules
ophal.modules.system = {}
ophal.modules.alpha = {
  route = function()
    return {
      ['alpha/page'] = { title = 'Alpha', page_callback = 'alpha_page' },
    }
  end,
}
ophal.modules.beta = {
  route = function()
    return {
      ['beta/page'] = { title = 'Beta', page_callback = 'beta_page' },
    }
  end,
}

dofile('includes/route.lua')

local routes = route_build_routes()
assert_eq('route_alpha_exists', routes['alpha/page'] ~= nil, true)
assert_eq('route_beta_exists', routes['beta/page'] ~= nil, true)
assert_eq('route_alpha_module', routes['alpha/page'].module, 'alpha')
assert_eq('route_beta_module', routes['beta/page'].module, 'beta')

-- 13. Route conflict: later module wins, warning emitted
setup_route_env()
settings.modules = { alpha = 1, beta = 2 }
dofile('includes/module.lua')

ophal.modules.system = {}
ophal.modules.alpha = {
  route = function()
    return {
      ['shared/page'] = { title = 'From Alpha', page_callback = 'alpha_page' },
    }
  end,
}
ophal.modules.beta = {
  route = function()
    return {
      ['shared/page'] = { title = 'From Beta', page_callback = 'beta_page' },
    }
  end,
}

dofile('includes/route.lua')

start_capture()
local conflict_routes = route_build_routes()
local conflict_stderr = stop_capture()

assert_eq('conflict_winner_title', conflict_routes['shared/page'].title, 'From Beta')
assert_eq('conflict_winner_module', conflict_routes['shared/page'].module, 'beta')
assert_match('conflict_warning_route', conflict_stderr, 'shared/page')
assert_match('conflict_warning_alpha', conflict_stderr, 'alpha')
assert_match('conflict_warning_beta', conflict_stderr, 'beta')

-- 14. Route freeze: new key errors
assert_error('freeze_new_key', function()
  conflict_routes['new/route'] = { title = 'Should fail' }
end)

-- 15. Route freeze: reading existing keys still works
assert_eq('freeze_read_ok', conflict_routes['shared/page'].title, 'From Beta')

-- ================================================================ summary

io.write(('\n%d passed, %d failed\n'):format(pass_count, fail_count))
if fail_count > 0 then
  os.exit(1)
end
