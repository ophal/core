--[[
  Unit tests for per-request state reset (Slice 4A).

  Verifies that ophal_request_reset() clears all per-request globals
  and closure locals, making lua_code_cache on safe in persistent runtimes.
]]

--[[ The real `os.exit`, captured before anything replaces it.

  This file `dofile`s `includes/server/init.lua`, which assigns
  `os.exit = server_exit` -- so the `os.exit(1)` in the summary below was the
  adapter's exit, not the interpreter's, and it did not set a failing status.
  The file printed "N passed, 1 failed" and exited **0**, and
  `run_unit_tests.sh` reported "all unit tests passed" over the top of it.

  `test_cookie_security.lua` loads the same file and already did this; this one
  did not. The project's own "did it actually run?" audit checked that every
  test file exits non-zero on failure and concluded they all do -- which was
  true of the source and false of the behaviour, because the call is right and
  the function underneath it is not.
]]
local real_os_exit = os.exit

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
  }
  env.ophal = _G.ophal

  -- The same split bootstrap installs, from the same module, so the assertions
  -- below are about the runtime's mechanism and not about a stub that models
  -- it. `_GET`, `base` and `ophal.title` keep their names; where the value
  -- lives is what changed.
  package.loaded['includes.request_state'] = nil
  require('includes.request_state').install(env)
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

  -- Track headers set during reset
  local headers_set = {}

  -- Mock adapter that returns configurable request data
  local mock_request = {
    scheme = 'http',
    host = 'localhost',
    script_name = '/index.lua',
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

io.write '\n-- adapter decoding --\n'
-- ================================================================

do
  setup_env()

  local query = server_parse_query('name=Alice+Bob&token=a=b=c&path=%2Fdocs%2Fintro')
  local cookies = server_parse_cookies('alpha=one%20two; beta=three=four')

  assert_eq('query_decode_plus', query.name, 'Alice Bob')
  assert_eq('query_preserve_equals', query.token, 'a=b=c')
  assert_eq('query_decode_percent', query.path, '/docs/intro')
  assert_eq('cookie_decode_percent', cookies.alpha, 'one two')
  assert_eq('cookie_preserve_equals', cookies.beta, 'three=four')

  --[[ `ngx.decode_args` answers shapes `_GET` consumers do not expect, and
    `server_parse_query()` normalizes them. Both come back as strings here or
    the normalization has stopped happening.

    A valueless argument decodes to the boolean `true`, and a repeated one to a
    table. `pager_current_page()` runs `tonumber` over whatever `?page=`
    holds -- `tonumber(true)` and `tonumber({})` are both nil, which is a
    different page rather than an error, so neither would be loud.
  ]]
  local shapes = server_parse_query('flag&page=1&page=2&empty=')

  assert_eq('query_valueless_argument_is_a_string', shapes.flag, '')
  assert_eq('query_repeated_argument_takes_the_last', shapes.page, '2')
  assert_eq('query_empty_value_is_a_string', shapes.empty, '')
  assert_eq('query_repeated_argument_is_not_a_table',
    type(shapes.page), 'string')

  --[[ Cookies are percent-decoded *without* plus-as-space. `+` meaning a space
    is the form-encoding rule; RFC 6265 has none, so the parser this replaced
    turned a `+` in a cookie value into a space. Nothing Ophal stores in a
    cookie is affected -- a session id is hex and dashes -- but a module keeping
    a base64 value in one would have been.
  ]]
  local plus_cookies = server_parse_cookies('token=a+b; encoded=a%2Bb')

  assert_eq('cookie_value_keeps_a_plus', plus_cookies.token, 'a+b')
  assert_eq('cookie_value_decodes_an_escaped_plus', plus_cookies.encoded, 'a+b')

  -- A query argument still gets the form-encoding rule, which is where it
  -- belongs.
  assert_eq('query_value_still_decodes_a_plus',
    server_parse_query('token=a+b').token, 'a b')

  -- An absent or empty query string is an empty table, not nil.
  assert_eq('query_of_nil_is_empty', next(server_parse_query(nil)), nil)
  assert_eq('query_of_empty_string_is_empty',
    next(server_parse_query('')), nil)
  assert_eq('cookies_of_nil_is_empty', next(server_parse_cookies(nil)), nil)
end

--[[ The same answers with no `ngx` at all.

  `server_parse_query()` resolves `ngx.decode_args` and `ngx.unescape_uri` at
  load and keeps pure-Lua spellings behind them. Under `resty` the C ones always
  win, so nothing here would exercise the others -- and an adapter is exactly
  the file where a branch nobody runs sits until somebody needs it.

  So clear `ngx`, reload the adapter, and ask the same questions. This is the
  pattern `test_query_layer.lua` uses to drive `driver/resty_mysql.lua`'s
  missing-binding branch: an assertion about a runtime that is not this one has
  to say so out loud.
]]
do
  setup_env()

  local real_ngx = _G.ngx

  rawset(_G, 'ngx', nil)
  dofile('includes/server/adapter.lua')

  local query = server_parse_query('name=Alice+Bob&token=a=b=c&path=%2Fdocs%2Fintro&flag&page=1&page=2')
  local cookies = server_parse_cookies('token=a+b; alpha=one%20two')

  assert_eq('fallback_query_decode_plus', query.name, 'Alice Bob')
  assert_eq('fallback_query_preserve_equals', query.token, 'a=b=c')
  assert_eq('fallback_query_decode_percent', query.path, '/docs/intro')
  assert_eq('fallback_query_valueless_argument', query.flag, '')
  assert_eq('fallback_query_repeated_takes_the_last', query.page, '2')
  assert_eq('fallback_cookie_keeps_a_plus', cookies.token, 'a+b')
  assert_eq('fallback_cookie_decode_percent', cookies.alpha, 'one two')

  rawset(_G, 'ngx', real_ngx)
  dofile('includes/server/adapter.lua')

  -- And the adapter is back on the nginx primitives for everything below.
  assert_eq('adapter_restored_to_ngx',
    server_parse_query('token=a+b').token, 'a b')
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

--[[ The CSRF token is minted where it is rendered, not where it is registered.

  `init_js()` runs on every request and `csrf_token()` writes into `_SESSION`
  when the session has no token yet, so registering the resolved value gave
  every anonymous visitor a session file, a lock file and a `Set-Cookie` for a
  value most pages never emit -- `init_js()` sets `load_ophal_js` false on its
  last line, so a page that adds no script of its own returns '' from
  `get_js()`. Measured on the smoke suite's anonymous front page: 112 session
  bytes written to disk and thrown away unread, now 27.

  Both halves are asserted. A deferral that never resolves would be a silent
  CSRF failure on every form in the codebase, which is worse than the waste it
  replaced.
]]
do
  local minted = 0

  setup_common_env()
  _G.csrf_token = function()
    minted = minted + 1
    return 'token-from-the-session'
  end

  --[[ The settings block is encoded by the real `includes/json.lua`.

    This used to stub `dkjson` with an encoder that echoed its fields, because
    the shared stub beside it answered `{}` for everything and would have let a
    token that never reached the page pass this assertion. Neither stub is
    reachable now: `includes/common.lua` encodes through the shim, which is
    cjson, so the token either survives into the rendered page or it does not.
  ]]
  dofile('includes/common.lua')

  common_reset_request()
  assert_eq('init_js_mints_no_csrf_token', minted, 0)

  -- Nothing has added a script, so nothing is emitted and nothing is minted.
  assert_eq('empty_page_emits_no_js', get_js(), '')
  assert_eq('empty_page_mints_no_csrf_token', minted, 0)

  -- A module adds one line of script, and now the settings block renders.
  add_js {type = 'inline', 'console.log(1)'}
  local rendered = get_js()
  local header = rendered and rendered.header or ''

  assert_eq('rendered_page_mints_the_csrf_token', minted, 1)
  assert_truthy('rendered_page_carries_the_csrf_token',
    header:find('token%-from%-the%-session'))

  _G.csrf_token = nil
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
  env.output_buffer[1] = 'stale output'

  --[[ Start this simulated request with no cached route arguments.

    `route_arg()` memoizes into `state.route_arguments`, and in production a new
    request means a new `ngx.ctx`, so that cache is empty by construction. This
    file simulates several requests inside one process against one state table,
    so the block above -- which parsed `admin` -- leaves its arguments behind.
    The setup has to do what a new request does.

    This assertion had been failing -- on both VMs, not only on LuaJIT -- and
    nobody saw it, because this file's `os.exit(1)` had been replaced by the
    adapter's and the suite read its exit status as success. It surfaced during
    the move to LuaJIT only because that move made someone read the output.
  ]]
  route_arg_reset()

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
  assert_nil('reset_output_buffer', env.output_buffer[1])

  -- 6. Route state cleared — route_arg returns new path
  assert_eq('reset_route_arg_0', route_arg(0), 'tag')
  assert_eq('reset_route_arg_1', route_arg(1), '5')

  -- 7. Default headers re-set
  assert_truthy('reset_headers', headers_set['content-type'])
end

-- ================================================================
io.write '\n-- request reset session ordering --\n'
-- ================================================================

do
  setup_env()
  settings.sessionapi = {enabled = true}

  local real_io_write = io.write
  dofile('includes/server/init.lua')
  io.write = real_io_write

  local order = {}
  local csrf_seen_by_common

  session_init = function()
    order[#order + 1] = 'session_init'
    _SESSION = {csrf_token = 'current-request-token'}
  end
  session_start = function()
    order[#order + 1] = 'session_start'
  end
  common_reset_request = function()
    order[#order + 1] = 'common_reset_request'
    csrf_seen_by_common = _SESSION and _SESSION.csrf_token
  end

  ophal_request_reset()

  assert_eq('reset_order_session_init', order[1], 'session_init')
  assert_eq('reset_order_session_start', order[2], 'session_start')
  assert_eq('reset_order_common', order[3], 'common_reset_request')
  assert_eq('reset_common_sees_current_session', csrf_seen_by_common, 'current-request-token')
end

-- ================================================================
io.write '\n-- session_init per-request --\n'
-- ================================================================

do
  local mock_request = setup_env()
  -- `includes/session.lua` captures `safe_open` at load time, so the recording
  -- stub has to be in place before the dofile below rather than beside the
  -- assertions that read it.
  local opened, cookies = {}, {}
  -- A directory of this test's own, because `session_start()` now asks the
  -- filesystem whether a presented id names a session it actually holds. A
  -- shared `/tmp` would make that answer depend on what another run left behind.
  local session_dir = (function()
    local path = os.tmpname()
    os.remove(path)
    os.execute(("mkdir -p '%s'"):format(path))
    return path
  end)()
  -- Extra stubs for session.lua
  _G.seawolf.behaviour = {temp_dir = function() return session_dir end}
  _G.seawolf.fs.safe_open = function(path)
    opened[#opened + 1] = path
    return {close = function() end, read = function() return '' end}, 'sign'
  end
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
  -- Session ids come from `includes/random.lua` now. `isvalid` above still
  -- gates what arrives in the cookie, so both are stubbed: the generator here
  -- and the format check on `uuid`.
  package.loaded['includes.random'] = {
    uuid = function() uuid_counter = uuid_counter + 1; return 'new-uuid-' .. uuid_counter end,
    hex = function(n) return ('a'):rep(n * 2) end,
    bytes = function(n) return ('x'):rep(n) end,
    reset = function() end,
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

  --[[ 2b. A well-formed id the server holds no file for is not resumed.

    Before this, `session_start()` handed any uuid-shaped cookie to
    `safe_open()`, which *creates* the file it cannot find. So an attacker
    looping over random uuids minted a session file and a lock file per request,
    with cron's daily sweep as the only reaper, and an id they had planted on a
    victim's browser was adopted as that visitor's session.

    Both halves are asserted: the id is dropped, and `safe_open` is never
    reached -- a demotion that still opened the file would fix the fixation and
    leave the flooding.
  ]]
  do
    local before = #opened

    mock_request.cookies = {['session-id'] = 'ghi-jkl-mno'}
    ophal.cookies = mock_request.cookies
    session_init()
    assert_eq('unknown_id_is_resumed_until_checked', ophal.session.resumed, true)

    session_start()

    assert_nil('unknown_session_id_is_dropped', ophal.session.id)
    assert_eq('unknown_session_is_not_resumed', ophal.session.resumed, false)
    assert_eq('unknown_session_opens_no_file', #opened, before)
    assert_eq('unknown_session_reads_as_empty', _SESSION.anything, nil)
  end

  --[[ 2c. An id the server does hold is resumed, which is the other half.

    A demotion that fired for every request would pass 2b and sign every
    returning visitor out, so the file is really created here and the resume
    really has to find it.
  ]]
  do
    local before = #opened
    local held = session_dir .. '/pqr-stu-vwx.ophal'
    local fh = assert(io.open(held, 'w'))

    fh:write 'return {}'
    fh:close()

    mock_request.cookies = {['session-id'] = 'pqr-stu-vwx'}
    ophal.cookies = mock_request.cookies
    session_init()
    session_start()

    assert_eq('held_session_keeps_its_id', ophal.session.id, 'pqr-stu-vwx')
    assert_eq('held_session_is_resumed', ophal.session.resumed, true)
    assert_eq('held_session_opens_the_file', #opened, before + 1)

    os.remove(held)

    -- The block below counts opens from zero rather than from a baseline, so
    -- the recorder is cleared here rather than that block being rewritten.
    for i = #opened, 1, -1 do
      opened[i] = nil
    end
  end

  --[[ 3. An invalid or absent cookie now yields **no session at all** here.

    This assertion used to be `session_new_uuid`: an id was minted and the
    cookie set inside `session_init()`, on every request, for every visitor. It
    is deliberately inverted rather than deleted -- the id is minted at the
    first write into `_SESSION`, and both halves are pinned so that "lazy" can
    never quietly become "never".
  ]]
  _G.cookie_set = function(name, value)
    cookies[#cookies + 1] = {name = name, value = value}
  end
  env.cookie_set = _G.cookie_set

  mock_request.cookies = {['session-id'] = 'bad'}
  ophal.cookies = mock_request.cookies
  session_init()

  assert_nil('session_without_a_cookie_has_no_id', ophal.session.id)
  assert_eq('session_without_a_cookie_is_not_resumed', ophal.session.resumed, false)
  assert_eq('session_init_sets_no_cookie', #cookies, 0)

  session_start()

  assert_eq('lazy_session_opens_no_file', #opened, 0)
  assert_eq('lazy_session_is_not_open', ophal.session.open, nil)
  assert_eq('lazy_session_reads_as_empty', _SESSION.anything, nil)
  assert_eq('reading_a_lazy_session_costs_nothing', #opened, 0)

  -- The first write is what buys the id, the cookie and the file.
  _SESSION.user_id = 7

  assert_truthy('writing_mints_an_id', ophal.session.id:find('^new%-uuid%-'))
  assert_eq('writing_sets_the_cookie', #cookies, 1)
  assert_eq('writing_sets_the_session_cookie', cookies[1].name, 'session-id')
  assert_eq('writing_opens_the_file', #opened, 1)
  assert_eq('writing_marks_the_session_open', ophal.session.open, true)
  assert_eq('the_written_value_survives', _SESSION.user_id, 7)

  -- The hook is dropped once it has fired, so the session is an ordinary table
  -- from here rather than one that re-enters materialization per key.
  _SESSION.other = 8
  assert_eq('a_second_write_opens_nothing_more', #opened, 1)
  assert_eq('the_second_value_survives', _SESSION.other, 8)
end

io.write '\n-- session regeneration on privilege change --\n'
-- ================================================================

--[[ Signing in must not keep the id the request arrived with.

  `session_init()` accepts any well-formed id the cookie presents, so carrying
  it into an authenticated session is fixation: plant an id on a visitor's
  browser, wait for them to sign in, and the planted id is theirs. These pin the
  rotation and the three things that have to travel with it -- the cookie, the
  data, and the removal of the file the old id named.
]]
do
  local mock_request = setup_env()
  local opened, removed, cookies_set = {}, {}, {}

  _G.seawolf.behaviour = {temp_dir = function() return '/tmp' end}
  _G.seawolf.fs.safe_open = function(path)
    opened[#opened + 1] = path
    return {close = function() end, read = function() return '' end}, 'sign-' .. #opened
  end
  _G.seawolf.fs.safe_write = function() return true end
  _G.seawolf.fs.safe_close = function(path) end
  _G.seawolf.contrib = _G.seawolf.contrib or {}
  _G.seawolf.contrib.table_dump = function() end
  env.seawolf = _G.seawolf
  _G.base = _G.base or {}
  _G.base.route = '/'
  env.base = _G.base

  local uuid_counter = 0
  _G.uuid = {
    isvalid = function(v) return v and #v > 5 end,
    new = function() uuid_counter = uuid_counter + 1; return 'rotated-' .. uuid_counter end,
  }
  package.loaded['includes.random'] = {
    uuid = function() uuid_counter = uuid_counter + 1; return 'rotated-' .. uuid_counter end,
    hex = function(n) return ('a'):rep(n * 2) end,
    bytes = function(n) return ('x'):rep(n) end,
    reset = function() end,
  }
  env.uuid = _G.uuid
  _G.cookie_set = function(name, value)
    cookies_set[#cookies_set + 1] = {name = name, value = value}
  end
  env.cookie_set = _G.cookie_set
  _G.get_cookie_domain = function() return 'localhost' end
  env.get_cookie_domain = _G.get_cookie_domain

  mock_request.cookies = {['session-id'] = 'planted-session-id'}
  ophal.cookies = mock_request.cookies

  dofile('includes/session.lua')

  local real_remove = os.remove
  os.remove = function(path) removed[#removed + 1] = path return true end

  session_init()
  assert_eq('regen_starts_from_the_presented_id',
    ophal.session.id, 'planted-session-id')

  -- Stand in for `session_start()` having opened the file, which is the state
  -- a sign-in actually rotates from.
  ophal.session.file.name = '/tmp/planted-session-id.ophal'
  ophal.session.file.sign = 'sign-0'
  ophal.session.open = true
  _SESSION = {cart = 'kept'}
  ophal.session.data = _SESSION

  local new_id = session_regenerate()

  assert_truthy('regen_returns_the_new_id', new_id and new_id:find('^rotated%-'))
  assert_eq('regen_changes_the_session_id', ophal.session.id, new_id)
  assert_eq('regen_id_is_not_the_planted_one',
    ophal.session.id == 'planted-session-id', false)

  -- The cookie has to move with it, or the browser keeps presenting the old id
  -- and the next request rotates again forever.
  assert_eq('regen_sets_the_cookie',
    cookies_set[#cookies_set] and cookies_set[#cookies_set].name, 'session-id')
  assert_eq('regen_cookie_carries_the_new_id',
    cookies_set[#cookies_set] and cookies_set[#cookies_set].value, new_id)

  -- Left behind, the old id is the same fixation with an expiry on it.
  assert_eq('regen_removes_the_old_file',
    removed[1], '/tmp/planted-session-id.ophal')

  -- Anything a `user_login` hook wrote before the account is set must survive.
  assert_eq('regen_keeps_the_session_data', (_SESSION or {}).cart, 'kept')
  assert_eq('regen_data_is_the_live_table', ophal.session.data, _SESSION)

  -- Reopened under the new name, so this request's writes land there.
  assert_eq('regen_opens_the_new_file',
    opened[#opened], '/tmp/' .. new_id .. '.ophal')
  assert_eq('regen_marks_the_session_open', ophal.session.open, true)

  os.remove = real_remove
end

-- ================================================================ summary

io.write(('\n%d passed, %d failed\n'):format(pass_count, fail_count))
if fail_count > 0 then
  real_os_exit(1)
end
