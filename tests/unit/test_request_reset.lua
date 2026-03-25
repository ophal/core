--[[
  Unit tests for per-request state reset (Slice 4A).

  Verifies that ophal_request_reset() clears all per-request globals
  and closure locals, making lua_code_cache on safe in persistent runtimes.
]]

local pass_count, fail_count = 0, 0

local function assert_eq(label, got, expected)
  if got == expected then
    pass_count = pass_count + 1
    io.write(('  ok %s\n'):format(label))
  else
    fail_count = fail_count + 1
    io.write(('  FAIL %s: expected %s, got %s\n'):format(
      label, tostring(expected), tostring(got)))
  end
end

local function assert_nil(label, got)
  assert_eq(label, got, nil)
end

local function assert_truthy(label, got)
  if got then
    pass_count = pass_count + 1
    io.write(('  ok %s\n'):format(label))
  else
    fail_count = fail_count + 1
    io.write(('  FAIL %s: expected truthy, got %s\n'):format(label, tostring(got)))
  end
end

-- ================================================================
-- Minimal environment for loading includes/server/init.lua and friends
-- ================================================================

local function setup_env()
  -- Reset global state
  _G.env = setmetatable({}, {__index = _G})
  _G.ophal = {
    version = 'test/1.0',
    output_buffer = {},
  }
  env.ophal = _G.ophal
  env.output_buffer = _G.ophal.output_buffer
  _G.base = {}
  env.base = _G.base
  _G.settings = {
    site = {frontpage = 'content'},
    locale = {},
    output_buffering = false,
    slash = '/',
  }
  env.settings = _G.settings

  -- Stub seawolf
  _G.seawolf = {
    variable = {empty = function(v) return v == nil or v == '' or v == 0 or v == false end},
    text = {
      trim = function(s, chars) return (s or ''):match('^%s*(.-)%s*$') end,
      explode = function(sep, s)
        local t = {}
        for w in s:gmatch('[^' .. sep .. ']+') do t[#t+1] = w end
        return t
      end,
      ltrim = function(s) return (s or ''):match('^%s*(.*)$') end,
      rtrim = function(s) return (s or ''):match('^(.-)%s*$') end,
    },
    fs = {
      dirname = function(s) return s:match('^(.+)/[^/]*$') or '' end,
      basename = function(s) return s:match('[^/]+$') or s end,
    },
    contrib = {parse_date = function() return 0 end},
  }
  env.seawolf = _G.seawolf

  -- Stub socket.url.unescape (used by adapter.lua)
  _G.socket = {url = {unescape = function(s) return s end}}
  env.socket = _G.socket

  -- Track headers set during reset
  local headers_set = {}

  -- Mock adapter that returns configurable request data
  local mock_request = {
    scheme = 'http',
    host = 'localhost',
    script_name = '/index.cgi',
    uri = '/',
    path = '',
    query = {},
    headers = {},
    cookies = {},
    raw_cookies = '',
  }
  local mock_adapter = {
    name = 'mock',
    request = function() return mock_request end,
    header = function(name, value) headers_set[name] = value end,
    cookie = function() end,
    write = function() end,
    redirect = function() end,
    finish = function() end,
  }

  -- Provide server_get_adapter / server_get_request / server_register_adapter
  -- Load the adapter module first
  _G.server_register_adapter = nil
  _G.server_get_adapter = nil
  _G.server_get_request = nil

  dofile('includes/server/adapter.lua')

  -- Register our mock adapter
  server_register_adapter('mock', mock_adapter)

  return mock_request, mock_adapter, headers_set
end

-- ================================================================
io.write '\n-- route reset --\n'
-- ================================================================

-- Test route_arg_reset and init_route_reset
do
  local mock_request = setup_env()

  -- Set up globals expected by route.lua
  _G.ophal.aliases = {source = {}, alias = {}}
  _G.ophal.redirects = {source = {}, target = {}}
  _G.seawolf.contrib = _G.seawolf.contrib or {}
  _G.seawolf.contrib.table_shift = function(t)
    local shifted = {}
    for i = 2, #t do shifted[#shifted+1] = t[i] end
    return shifted
  end
  env.seawolf = _G.seawolf
  env.ophal = _G.ophal
  _G.route_set_title = function() end
  env.route_set_title = _G.route_set_title
  _G.module_invoke_all = _G.module_invoke_all or function() end
  env.module_invoke_all = _G.module_invoke_all
  _G.db_query = function() end
  env.db_query = _G.db_query
  _G.request_path = function() return server_get_request().path or '' end
  env.request_path = _G.request_path
  _G.explode = _G.seawolf.text.explode
  env.explode = _G.explode

  mock_request.path = 'content/42'

  dofile('includes/route.lua')

  -- 1. route_arg returns values from the path
  assert_eq('route_arg_initial_0', route_arg(0), 'content')
  assert_eq('route_arg_initial_1', route_arg(1), '42')

  -- 2. route_arg_reset clears cached arguments
  route_arg_reset()
  -- Change the request path
  mock_request.path = 'tag/5'
  -- Force adapter to return fresh request
  server_get_request(true)
  assert_eq('route_arg_after_reset_0', route_arg(0), 'tag')
  assert_eq('route_arg_after_reset_1', route_arg(1), '5')

  -- 3. init_route builds and resets
  local tree1, route1 = init_route()
  assert_truthy('init_route_built', #tree1 > 0)

  init_route_reset()
  route_arg_reset()
  mock_request.path = 'user/login'
  server_get_request(true)
  local tree2, route2 = init_route()
  assert_eq('init_route_after_reset', route2, 'user/login')

  -- 4. route_reset_request calls both
  route_reset_request()
  mock_request.path = 'admin'
  server_get_request(true)
  assert_eq('route_reset_request_arg', route_arg(0), 'admin')
  local tree3, route3 = init_route()
  assert_eq('route_reset_request_route', route3, 'admin')
end

-- ================================================================
io.write '\n-- common reset --\n'
-- ================================================================

-- Helper: setup stubs for common.lua loading
local function setup_common_env()
  setup_env()

  -- Stub seawolf for require
  local sw = _G.seawolf
  sw.maths = {round = function(n) return math.floor(n + 0.5) end}
  sw.text.str_replace = function(search, replace, subject) return (subject or ''):gsub(search, replace) end
  sw.fs.is_file = function() return false end
  sw.__build = function() return sw end
  package.loaded['seawolf'] = sw
  -- Stub dkjson for require
  package.loaded['dkjson'] = {encode = function() return '{}' end, decode = function() return {} end}

  -- lfs stub
  _G.lfs = {attributes = function() return {} end, dir = function() return function() end end}
  env.lfs = _G.lfs

  -- Stub theme for common.lua
  _G.theme = {
    name = 'basic',
    settings = {js = {}, css = {}, head = {}},
  }
  env.theme = _G.theme

  -- Stubs expected by common.lua
  _G.module_invoke_all = function() end
  env.module_invoke_all = _G.module_invoke_all
  _G.t = function(s) return s end
  env.t = _G.t
  _G.l = function(text, path) return '<a>' .. text .. '</a>' end
  env.l = _G.l

  -- Clear cached module so dofile re-executes
  package.loaded['includes.common'] = nil
end

do
  setup_common_env()

  dofile('includes/common.lua')

  -- 1. add_js accumulates state — use inline type so is_file isn't needed
  add_js {type = 'settings', namespace = 'test', {key = 'val1'}}
  local js1 = get_js()
  local js1_header = js1 and js1.header or ''
  assert_truthy('add_js_before_reset', js1_header:find('test'))

  -- 2. common_reset_request clears JS
  common_reset_request()
  add_js {type = 'settings', namespace = 'other', {key = 'val2'}}
  local js2 = get_js()
  local js2_header = js2 and js2.header or ''
  -- 'test' namespace should be gone, 'other' present
  assert_eq('common_reset_clears_js', js2_header:find('"test"'), nil)
  assert_truthy('common_reset_keeps_new_js', js2_header:find('"other"'))

  -- 3. page titles reset
  settings.site.name = 'Test Site'
  page_set_title('Old Title')
  assert_eq('title_set', ophal.title, 'Old Title')
  ophal.title = nil
  ophal.header_title = nil
  assert_nil('title_cleared', ophal.title)
end

-- ================================================================
io.write '\n-- ophal_request_reset --\n'
-- ================================================================

do
  setup_common_env()
  local mock_request, _, headers_set = setup_env()

  -- Re-apply common env stubs after setup_env reset
  local sw = _G.seawolf
  sw.maths = {round = function(n) return math.floor(n + 0.5) end}
  sw.__build = function() return sw end
  package.loaded['seawolf'] = sw
  package.loaded['dkjson'] = {encode = function() return '{}' end, decode = function() return {} end}
  _G.lfs = {attributes = function() return {} end, dir = function() return function() end end}
  env.lfs = _G.lfs
  _G.theme = {name = 'basic', settings = {js = {}, css = {}, head = {}}}
  env.theme = _G.theme
  _G.module_invoke_all = function() end
  env.module_invoke_all = _G.module_invoke_all
  _G.t = function(s) return s end
  env.t = _G.t
  _G.l = function(text, path) return '<a>' .. text .. '</a>' end
  env.l = _G.l

  -- Route dependencies
  _G.ophal.aliases = {source = {}, alias = {}}
  _G.ophal.redirects = {source = {}, target = {}}
  _G.seawolf.contrib = _G.seawolf.contrib or {}
  _G.seawolf.contrib.table_shift = function(t)
    local shifted = {}
    for i = 2, #t do shifted[#shifted+1] = t[i] end
    return shifted
  end
  env.seawolf = _G.seawolf
  env.ophal = _G.ophal
  _G.route_set_title = function() end
  env.route_set_title = _G.route_set_title
  _G.db_query = function() end
  env.db_query = _G.db_query
  _G.request_path = function() return server_get_request().path or '' end
  env.request_path = _G.request_path
  _G.explode = _G.seawolf.text.explode
  env.explode = _G.explode

  -- Simulate first request
  mock_request.path = 'content/1'
  mock_request.query = {page = '2'}
  mock_request.cookies = {['session-id'] = 'abc'}
  mock_request.raw_cookies = 'session-id=abc'

  local orig_io_write = io.write
  dofile('includes/route.lua')
  dofile('includes/common.lua')
  dofile('includes/server/init.lua')
  -- Restore io.write — server/init.lua replaces it with the adapter's write
  io.write = orig_io_write

  -- Populate state as if first request ran
  _GET = {page = '2'}
  ophal.title = 'First Page'
  ophal.header_title = 'First'
  ophal.blocks = {sidebar = {}}
  ophal.regions = {content = 'html'}
  ophal.output_buffer[1] = 'stale output'

  -- Parse route for first request
  assert_eq('pre_reset_arg', route_arg(0), 'content')

  -- Now simulate second request with different data
  mock_request.path = 'tag/5'
  mock_request.query = {format = 'json'}
  mock_request.cookies = {['session-id'] = 'xyz'}
  mock_request.raw_cookies = 'session-id=xyz'

  -- Run the reset
  ophal_request_reset()

  -- 1. _GET reflects new request
  assert_eq('reset_GET_page', _GET.page, nil)
  assert_eq('reset_GET_format', _GET.format, 'json')

  -- 2. Cookies reflect new request
  assert_eq('reset_cookies', ophal.cookies['session-id'], 'xyz')
  assert_eq('reset_raw_cookies', ophal.raw_cookies, 'session-id=xyz')

  -- 3. Title cleared
  assert_nil('reset_title', ophal.title)
  assert_nil('reset_header_title', ophal.header_title)

  -- 4. Blocks and regions cleared
  assert_nil('reset_blocks_sidebar', ophal.blocks.sidebar)
  assert_nil('reset_regions_content', ophal.regions.content)

  -- 5. Output buffer cleared
  assert_nil('reset_output_buffer', ophal.output_buffer[1])

  -- 6. Route state cleared — route_arg returns new path
  assert_eq('reset_route_arg_0', route_arg(0), 'tag')
  assert_eq('reset_route_arg_1', route_arg(1), '5')

  -- 7. Default headers re-set
  assert_truthy('reset_headers', headers_set['content-type'])
end

-- ================================================================
io.write '\n-- session_init per-request --\n'
-- ================================================================

do
  local mock_request = setup_env()
  -- Extra stubs for session.lua
  _G.seawolf.behaviour = {temp_dir = function() return '/tmp' end}
  _G.seawolf.fs.safe_open = function() return nil end
  _G.seawolf.fs.safe_write = function() return true end
  _G.seawolf.fs.safe_close = function() end
  _G.seawolf.contrib = _G.seawolf.contrib or {}
  _G.seawolf.contrib.table_dump = function() end
  env.seawolf = _G.seawolf
  _G.base = _G.base or {}
  _G.base.route = '/'
  env.base = _G.base

  mock_request.cookies = {['session-id'] = 'aaa-bbb-ccc'}
  ophal.cookies = mock_request.cookies

  -- Stub uuid
  local uuid_counter = 0
  _G.uuid = {
    isvalid = function(s) return s and #s > 5 end,
    new = function() uuid_counter = uuid_counter + 1; return 'new-uuid-' .. uuid_counter end,
  }
  env.uuid = _G.uuid
  _G.cookie_set = function() end
  env.cookie_set = _G.cookie_set
  _G.get_cookie_domain = function() return 'localhost' end
  env.get_cookie_domain = _G.get_cookie_domain

  dofile('includes/session.lua')

  -- 1. session_init picks up cookie
  session_init()
  assert_eq('session_init_id', ophal.session.id, 'aaa-bbb-ccc')

  -- 2. Change cookies, re-init
  mock_request.cookies = {['session-id'] = 'ddd-eee-fff'}
  ophal.cookies = mock_request.cookies
  session_init()
  assert_eq('session_reinit_id', ophal.session.id, 'ddd-eee-fff')

  -- 3. Invalid cookie generates new UUID
  mock_request.cookies = {['session-id'] = 'bad'}
  ophal.cookies = mock_request.cookies
  session_init()
  assert_truthy('session_new_uuid', ophal.session.id:find('^new%-uuid%-'))
end

-- ================================================================ summary

io.write(('\n%d passed, %d failed\n'):format(pass_count, fail_count))
if fail_count > 0 then
  os.exit(1)
end
