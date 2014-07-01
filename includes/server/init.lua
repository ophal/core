local buffer = env.output_buffer
local time, date, exit = os.time, os.date, os.exit
local tinsert, explode = table.insert, seawolf.text.explode
local empty, ltrim = seawolf.variable.empty, seawolf.text.ltrim
local trim, dirname = seawolf.text.trim, seawolf.fs.dirname
local basename = seawolf.fs.basename
local rtrim, unescape = seawolf.text.rtrim, socket.url.unescape
local tconcat, lower = table.concat, string.lower

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
if ophal.version then
  header('x-powered-by', ophal.version)
end

-- Browser cache control
if settings.cache and _SERVER 'HTTP_IF_MODIFIED_SINCE' ~= nil then
  header('status', '304 Not Modified')
  header('cache-control', 'must-revalidate')
  exit()
end

-- Redirect to mobile domain name
if settings.mobile then
  local domain_name = settings.mobile.domain_name
  local uri = _SERVER 'REQUEST_URI'
  if settings.mobile.redirect and mobile.detect.isMobile() and _SERVER 'HTTP_HOST' ~= domain_name then
    local redirect_url = domain_name .. (_SERVER 'REQUEST_URI' or '')
    header('Location', 'http://' .. redirect_url)
    print(('Redirecting to <a href="http://%s">http://%s</a>.'):format(redirect_url, redirect_url))
    os.exit()
  end
end

-- Set headers for dynamic content
header('expires', 'Sun, 19 Nov 1978 05:00:00 GMT')
header('last-modified', date('!%a, %d %b %Y %X GMT', time(date('*t')) - 15*60))
header('cache-control', 'store, no-cache, must-revalidate, post-check=0, pre-check=0')
header('Keep-Alive', 'timeout=15, max=90')

--[[
  Since _SERVER['REQUEST_URI'] is only available on Apache, we
  generate an equivalent using other environment variables.

  Copied and adapted from Drupal 8.x request_uri().
 ]]
function request_uri(omit_query_string)
  local uri

  if _SERVER 'REQUEST_URI' ~= nil then
    uri = _SERVER 'REQUEST_URI'
  else
    if _SERVER 'QUERY_STRING' ~= nil then
      uri = _SERVER 'SCRIPT_NAME' .. '?' .. _SERVER 'QUERY_STRING'
    else
      uri = _SERVER 'SCRIPT_NAME' or ''
    end
  end
  -- Prevent multiple slashes to avoid cross site requests via the FAPI.
  uri = '/'.. ltrim(uri, '/')

  if omit_query_string then
    for _, v in pairs(explode('?', uri)) do
      if v ~= '' then
        return v
      end
    end
  end

  return uri
end

do
  local path

  --[[
    Returns the requested URL path of the page being viewed.

    Examples:
    - http://example.com/article/306 returns "article/306".
    - http://example.com/ophalfolder/article/306 returns "article/306" while
      base.route() returns "/ophalfolder/".
    - http://example.com/path/alias (which is a path alias for article/306)
      returns "path/alias" as opposed to the internal path.
    - http://example.com/index.cgi returns an empty string, meaning: front page.
    - http://example.com/index.cgi?page=1 returns an empty string.

     Copied and adapted from Drupal 8.x request_path().
   ]]
  function request_path()
    local request_path, base_route_len, script

    if path ~= nil then
      return path
    end

    -- Get the part of the URI between the base path of the Drupal installation
    -- and the query string, and unescape it.
    request_path = request_uri(true)
    base_route_len = rtrim(dirname(_SERVER 'SCRIPT_NAME'), '\/'):len()
    path = unescape(request_path):sub(base_route_len + 1)

    -- Depending on server configuration, the URI might or might not include the
    -- script name. For example, the front page might be accessed as
    -- http://example.com or as http://example.com/index.cgi, and the "user"
    -- page might be accessed as http://example.com/user or as
    -- http://example.com/index.cgi/user. Strip the script name from $path.
    script = basename(_SERVER 'SCRIPT_NAME')
    if path == script then
      path = ''
    elseif path:find(script .. '/') == 0 then
      path = substr(path, strlen(script) + 1)
    end

    -- Extra slashes can appear in URLs or under some conditions, added by
    -- the web server, so normalize.
    path = trim(path, '/')

    return path
  end
end

-- Build base URL, system_root, route and path
function build_base()
  base.system_root = (_SERVER 'HTTPS' ~= nil and _SERVER 'HTTPS' == 'on') and 'https' or 'http'
  base.system_root = base.system_root .. '://' .. (_SERVER 'HTTP_HOST' or 'default')
  base.url = base.system_root
  base.path = request_path()

  local dir = seawolf.text.trim(seawolf.fs.dirname(_SERVER 'SCRIPT_NAME' or '/index.cgi'), [[\,/]])
  if dir ~= '' then
    base.route = '/' .. dir
    base.url = base.url .. base.route
    base.route = base.route .. '/'
  end
end

-- Parse query string
local list = explode('&', _SERVER 'QUERY_STRING' or '')

local parsed = {}
if list then
  local tmp, key, value
  for _, v in pairs(list) do
    if #v > 0 then
      tmp = explode('=', v)
      key = unescape((tmp[1] or ''):gsub('+', ' '))
      value = unescape((tmp[2] or ''):gsub('+', ' '))
      parsed[key] = value
    end
  end
end
_GET = parsed

-- output buffering
do
  local write_orig = write
  local exit_orig = exit
  if settings.output_buffering then
    write = function (s)
      local type_ = type(s)
      if type_ ~= 'string' then
        s = ('(%s)'):format(type_)
      end
      tinsert(buffer, #buffer + 1, s)
    end
    io.write = write
    exit = function (code)
      output_flush()
      exit_orig(code)
    end
    os.exit = exit
    local error_orig = error
    error = function (s)
      output_flush()
      error_orig(s)
    end
  end

  function output_clean()
    for k, v in pairs(buffer) do
      buffer[k] = nil -- wipe buffer
    end
    -- restore output function
    write = write_orig
    io.write = write_orig
    -- turn off output buffering
    settings.output_buffering = false
  end
end

function output_get_clean()
  local output = tconcat(buffer)
  output_clean()
  return output
end

function output_flush()
  -- WARNING! need to get output first and then write it, since output function
  -- is controlled by output_clean()
  local output = output_get_clean()
  -- NOTICE! most times this is the first ever call to write(), which takes care
  -- of headers, don't use io_write()!
  write(output)
end
