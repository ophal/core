local request_state = require 'includes.request_state'
local http_cache = require 'includes.http_cache'

--[[ This request's output buffer.

  Read through `env` on every call rather than captured here. The buffer is
  request state now, so a load-time capture would pin this worker to whichever
  request happened to load the file -- the same defect this file's
  `ophal_request_reset()` exists to prevent, one level up.
]]
local function output_buffer()
  return env.output_buffer
end

local time, date = os.time, os.date
local tinsert = table.insert
local empty = seawolf.variable.empty
local trim, dirname = seawolf.text.trim, seawolf.fs.dirname
local parse_date = seawolf.contrib.parse_date
local tconcat, lower = table.concat, string.lower

local function request_header(name)
  local headers = (server_get_request().headers or {})
  return headers[name] or headers[lower(name)]
end

--[[ The first byte is where the response stops being negotiable.

  Headers are gone once the body starts, so this is the last point at which
  `includes/http_cache.lua` can say what the response is -- and, because Ophal's
  handlers load their data and then print, it is also the first point at which
  every projection version the page depends on has been read.

  A 304 is expressed as "drop every write for the rest of the request" rather
  than as an early exit. The shutdown path then runs exactly as it does for any
  other response: modules get their exit hook, the session is written back, and
  connections are released.
]]
function write(s)
  local adapter = server_get_adapter()

  if http_cache.finalize(adapter, server_get_request()) then
    return
  end

  return adapter.write(s)
end
io.write = write

function header(name, value, replace)
  return server_get_adapter().header(name, value, replace)
end

function redirect(dest_url, http_response_code)
  return server_get_adapter().redirect(dest_url, http_response_code)
end

function server_exit(status)
  return server_get_adapter().finish(status)
end
os.exit = server_exit

local request = server_get_request()
_GET = request.query or {}
ophal.raw_cookies = request.raw_cookies or ''
ophal.cookies = request.cookies or {}

--[[ Ophal's print function.

  It is the unique Ophal's output function, *write() is for internal use only*.
]]
function print(s)
  write(tostring(s))
end

function echo(...)
  for _, v in pairs({...}) do
    write(tostring(v))
  end
end

-- Default headers
header('content-type', 'text/html; charset=utf-8')
header('x-frame-options', 'SAMEORIGIN')
if ophal.version then
  header('x-powered-by', ophal.version)
end

--[[ `settings.micro_cache` was here and is gone.

  It answered 304 to any client whose `If-Modified-Since` was within five
  seconds of *now* -- no validator, no reference to the page, no idea whether
  anything had changed. A page edited inside that window was served as
  unchanged, and one untouched for a year was served in full the moment the
  window lapsed. It was off by default, which is the only reason it never cost
  anybody anything.

  `includes/http_cache.lua` replaces it with a validator derived from the
  projection versions the response was actually built from.
]]

-- Redirect to mobile domain name
if settings.mobile then
  local domain_name = settings.mobile.domain_name
  if settings.mobile.redirect and mobile.detect.isMobile() and request.host ~= domain_name then
    local redirect_url = domain_name .. (request.uri or '')
    header('location', 'http://' .. redirect_url)
    print(('Redirecting to <a href="http://%s">http://%s</a>.'):format(redirect_url, redirect_url))
    os.exit()
  end
end

-- Set headers for dynamic content
header('expires', 'Sun, 19 Jun 2011 23:09:50 GMT')
header('last-modified', date('!%a, %d %b %Y %X GMT'))
header('cache-control', 'store, no-cache, must-revalidate, post-check=0, pre-check=0')
header('Keep-Alive', 'timeout=15, max=90')

function request_uri(omit_query_string)
  local uri = server_get_request().uri or '/'

  if omit_query_string then
    return uri:match('^[^?]+') or uri
  end

  return uri
end

function request_path()
  return server_get_request().path or ''
end

-- Build base URL, system_root, route and path
function build_base()
  local req = server_get_request()

  if not empty((settings.site or {}).scheme) then
    base.scheme = settings.site.scheme
  else
    base.scheme = req.scheme or 'http'
  end
  base.system_root = base.scheme .. '://' .. ((settings.site or {}).domain_name or req.host or 'default')
  base.url = base.system_root
  base.path = req.path or ''

  local dir = trim(dirname(req.script_name or '/index.lua'), [[\,/]])
  if dir ~= '' then
    base.route = '/' .. dir
    base.url = base.url .. base.route
    base.route = base.route .. '/'
  end
end

-- output buffering
do
  local write_orig = write
  local exit_orig = server_exit
  if settings.output_buffering then
    write = function (s)
      local type_ = type(s)
      if type_ ~= 'string' then
        s = ('(%s)'):format(type_)
      end
      local buffer = output_buffer()
      tinsert(buffer, #buffer + 1, s)
    end
    io.write = write
    os.exit = function (code)
      output_flush()
      return exit_orig(code)
    end
    local error_orig = error
    error = function (s)
      output_flush()
      error_orig(s)
    end
  end

  function output_clean()
    local buffer = output_buffer()

    for k in pairs(buffer) do
      buffer[k] = nil
    end
    write = write_orig
    io.write = write_orig
    settings.output_buffering = false
  end
end

function output_get_clean()
  local output = tconcat(output_buffer())
  output_clean()
  return output
end

function output_flush()
  local output = output_get_clean()
  write(output)
end

function request_get_body()
  return server_get_request().body
end

--[[ The file nginx buffered this request's body into, or nil.

  For a caller that is only going to move the bytes somewhere else, this is the
  bytes already on disk -- taking the path and renaming the file skips the copy
  into a Lua string entirely. Reading `request_get_body()` after this still
  works and still costs that copy, so a caller takes one or the other.
]]
function request_get_body_file()
  return server_get_request().body_file
end

function get_cookie_domain()
  return
    (settings.site or {}).cookie_domain or
    server_get_request().host or
    _SERVER 'SERVER_NAME'
end

function cookie_set(name, value, expires, path, domain, extra_options)
  local defaults = (settings.cookie_defaults or {})
  local function default_option(value, fallback)
    if value ~= nil then
      return value
    end
    return fallback
  end

  local options = {
    domain = domain or '',
    path = path or '',
    http_only = default_option(defaults.http_only, true),
    same_site = defaults.same_site or 'Lax',
  }

  if base.scheme == 'https' then
    options.secure = default_option(defaults.secure, true)
  end

  if expires ~= nil then
    options.expires = expires + time()
  end

  -- Caller overrides (e.g. {http_only = false} for JS-readable cookies)
  if type(extra_options) == 'table' then
    for k, v in pairs(extra_options) do
      options[k] = v
    end
  end

  return server_get_adapter().cookie(name, value, options)
end

function cookie_parse()
  return server_parse_cookies(server_get_request().raw_cookies or '')
end

ophal.cookies = cookie_parse()

--[[ Reset all per-request state for OpenResty.
  With lua_code_cache on, the Lua VM persists across requests so globals
  and closure locals from the previous request must be cleared before
  handling a new one.
]]
function ophal_request_reset()
  -- Discard whatever the previous request left behind. Under nginx this is
  -- already true -- a new request arrives with a new `ngx.ctx` -- and the call
  -- is what makes it true for a standalone runtime as well.
  request_state.reset()

  -- Fresh request object from adapter
  local request = server_get_request(true)

  -- Re-set request-derived globals
  _GET = request.query or {}
  ophal.raw_cookies = request.raw_cookies or ''
  ophal.cookies = request.cookies or {}

  -- Clear page state
  ophal.title = nil
  ophal.header_title = nil

  -- Clear theme state (rebuilt in bootstrap phase 14)
  ophal.blocks = {}
  ophal.regions = {}

  -- Re-derive base URL from new request
  build_base()

  -- Re-set default response headers
  header('content-type', 'text/html; charset=utf-8')
  header('x-frame-options', 'SAMEORIGIN')
  if ophal.version then
    header('x-powered-by', ophal.version)
  end
  header('expires', 'Sun, 19 Jun 2011 23:09:50 GMT')
  header('last-modified', date('!%a, %d %b %Y %X GMT'))
  header('cache-control', 'store, no-cache, must-revalidate, post-check=0, pre-check=0')
  header('Keep-Alive', 'timeout=15, max=90')

  -- Reset route parsing state
  if type(route_reset_request) == 'function' then
    route_reset_request()
  end

  -- Reset and open the current request session before rebuilding JS settings.
  -- CSRF tokens are stored in _SESSION and must belong to this request.
  if settings.sessionapi and type(session_init) == 'function' then
    session_init()
    if type(session_start) == 'function' then
      session_start()
    end
  end

  -- Reset JS/CSS/head accumulators after session state is current.
  if type(common_reset_request) == 'function' then
    common_reset_request()
  end
end
