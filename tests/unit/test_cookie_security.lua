--[[
  Unit tests for cookie security hardening (Slice 5A).

  Verifies that cookie_set() applies HttpOnly, SameSite=Lax by default,
  Secure when HTTPS, caller override via extra_options, and backward
  compatibility with existing 5-argument callers.
]]

local pass_count, fail_count = 0, 0
local real_io_write = io.write
local real_os_exit = os.exit

local function assert_eq(label, got, expected)
  if got == expected then
    pass_count = pass_count + 1
    real_io_write(('  ok %s\n'):format(label))
  else
    fail_count = fail_count + 1
    real_io_write(('  FAIL %s: expected %s, got %s\n'):format(
      label, tostring(expected), tostring(got)))
  end
end

local function assert_truthy(label, got)
  if got then
    pass_count = pass_count + 1
    real_io_write(('  ok %s\n'):format(label))
  else
    fail_count = fail_count + 1
    real_io_write(('  FAIL %s: expected truthy, got %s\n'):format(label, tostring(got)))
  end
end

local function assert_nil(label, got)
  assert_eq(label, got, nil)
end

-- ================================================================
-- Environment setup
-- ================================================================

local last_cookie_options  -- captured by mock adapter

local function setup_env(scheme)
  _G.env = setmetatable({}, {__index = _G})
  _G.ophal = {
    version = 'test/1.0',
    output_buffer = {},
  }
  env.ophal = _G.ophal
  env.output_buffer = _G.ophal.output_buffer
  _G.base = {scheme = scheme or 'http'}
  env.base = _G.base
  _G.settings = {
    site = {frontpage = 'content'},
    locale = {},
    output_buffering = false,
    slash = '/',
  }
  env.settings = _G.settings

  _G.seawolf = {
    variable = {empty = function(v) return v == nil or v == '' or v == 0 or v == false end},
    text = {
      trim = function(s) return (s or ''):match('^%s*(.-)%s*$') end,
      explode = function(sep, s)
        local t = {}
        for w in s:gmatch('[^' .. sep .. ']+') do t[#t+1] = w end
        return t
      end,
    },
    fs = {
      dirname = function(s) return s:match('^(.+)/[^/]*$') or '' end,
      basename = function(s) return s:match('[^/]+$') or s end,
    },
    contrib = {parse_date = function() return 0 end},
  }
  env.seawolf = _G.seawolf
  _G.socket = {url = {unescape = function(s) return s end}}
  env.socket = _G.socket

  last_cookie_options = nil

  local mock_adapter = {
    name = 'mock',
    request = function()
      return {
        scheme = scheme or 'http',
        host = 'localhost',
        script_name = '/index.cgi',
        uri = '/',
        path = '',
        query = {},
        headers = {},
        cookies = {},
        raw_cookies = '',
      }
    end,
    header = function() end,
    cookie = function(name, value, options)
      last_cookie_options = options
    end,
    write = function() end,
    redirect = function() end,
    finish = function() end,
  }

  dofile('includes/server/adapter.lua')
  server_register_adapter('mock', mock_adapter)

  dofile('includes/server/init.lua')

  -- Server init intentionally swaps process globals for runtime helpers.
  -- Restore the test runner's IO and exit semantics so failures are visible.
  io.write = real_io_write
  os.exit = real_os_exit
end

-- ================================================================
real_io_write '\n-- default cookie flags (HTTP) --\n'
-- ================================================================

do
  setup_env('http')

  cookie_set('test', 'value', 3600, '/', 'example.com')

  assert_truthy('http_only_default', last_cookie_options.http_only == true)
  assert_eq('same_site_default', last_cookie_options.same_site, 'Lax')
  assert_nil('secure_absent_on_http', last_cookie_options.secure)
end

-- ================================================================
real_io_write '\n-- HTTPS adds Secure flag --\n'
-- ================================================================

do
  setup_env('https')
  -- base.scheme is set to 'https' by setup_env
  -- but build_base() may reset it; force it:
  base.scheme = 'https'

  cookie_set('test', 'value', 3600, '/', 'example.com')

  assert_truthy('secure_on_https', last_cookie_options.secure == true)
  assert_truthy('http_only_on_https', last_cookie_options.http_only == true)
  assert_eq('same_site_on_https', last_cookie_options.same_site, 'Lax')
end

-- ================================================================
real_io_write '\n-- caller override via extra_options --\n'
-- ================================================================

do
  setup_env('http')

  cookie_set('jstoken', 'abc', 3600, '/', 'example.com', {http_only = false})

  assert_eq('override_http_only', last_cookie_options.http_only, false)
  assert_eq('override_keeps_same_site', last_cookie_options.same_site, 'Lax')
end

-- ================================================================
real_io_write '\n-- settings.cookie_defaults override --\n'
-- ================================================================

do
  setup_env('http')
  settings.cookie_defaults = {same_site = 'Strict', http_only = false}

  cookie_set('test', 'value', 3600, '/', 'example.com')

  assert_eq('settings_same_site', last_cookie_options.same_site, 'Strict')
  assert_eq('settings_http_only', last_cookie_options.http_only, false)
end

-- ================================================================
real_io_write '\n-- settings.cookie_defaults can disable Secure on HTTPS --\n'
-- ================================================================

do
  setup_env('https')
  settings.cookie_defaults = {secure = false}

  cookie_set('test', 'value', 3600, '/', 'example.com')

  assert_eq('settings_secure_false', last_cookie_options.secure, false)
end

-- ================================================================
real_io_write '\n-- backward compat: 5-arg call works --\n'
-- ================================================================

do
  setup_env('http')

  -- Old-style 5-arg call — should not error
  local ok, err = pcall(cookie_set, 'session-id', 'abc-123', 3600, '/', 'example.com')
  assert_truthy('5_arg_no_error', ok)
  assert_truthy('5_arg_has_options', last_cookie_options ~= nil)
  assert_truthy('5_arg_http_only', last_cookie_options.http_only == true)
end

-- ================================================================
real_io_write '\n-- expires calculation --\n'
-- ================================================================

do
  setup_env('http')

  cookie_set('test', 'value', 7200, '/', 'example.com')

  assert_truthy('expires_set', last_cookie_options.expires ~= nil)
  -- expires should be > current time (time() + 7200)
  assert_truthy('expires_future', last_cookie_options.expires > os.time())
end

-- ================================================================ summary

real_io_write(('\n%d passed, %d failed\n'):format(pass_count, fail_count))
if fail_count > 0 then
  real_os_exit(1)
end
