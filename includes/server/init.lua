local buffer = env.output_buffer
local time, date = os.time, os.date
local tinsert = table.insert
local empty = seawolf.variable.empty
local base, trim, dirname = base, seawolf.text.trim, seawolf.fs.dirname
local parse_date = seawolf.contrib.parse_date
local tconcat, lower = table.concat, string.lower

local function request_header(name)
  local headers = (server_get_request().headers or {})
  return headers[name] or headers[lower(name)]
end

function write(s)
  return server_get_adapter().write(s)
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

-- Browser micro cache control
do
  local if_modified_since = request_header 'If-Modified-Since'

  if settings.micro_cache and if_modified_since ~= nil then
    local parsed = parse_date(if_modified_since)
    local last_access = tonumber(('%s%s%s%s%s%s'):format(parsed.year, parsed.month, parsed.day, parsed.hours, parsed.minutes, parsed.seconds))
    local now = tonumber(os.date('%Y%m%d%H%M%S', time()))
    if last_access + 5 >= now then
      header('status', '304 Not Modified')
      header('cache-control', 'must-revalidate')
      print ''
      os.exit()
    end
  end
end

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

  local dir = trim(dirname(req.script_name or '/index.cgi'), [[\,/]])
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
    for k in pairs(buffer) do
      buffer[k] = nil
    end
    write = write_orig
    io.write = write_orig
    settings.output_buffering = false
  end
end

function output_get_clean()
  local output = tconcat(buffer)
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

function get_cookie_domain()
  return
    (settings.site or {}).cookie_domain or
    server_get_request().host or
    _SERVER 'SERVER_NAME'
end

function cookie_set(name, value, expires, path, domain)
  local options = {
    domain = domain or '',
    path = path or '',
  }

  if expires ~= nil then
    options.expires = expires + time()
  end

  return server_get_adapter().cookie(name, value, options)
end

function cookie_parse()
  return server_parse_cookies(server_get_request().raw_cookies or '')
end

ophal.cookies = cookie_parse()
