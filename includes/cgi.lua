local io_write, write, buffer = io.write, io.write, env.output_buffer
local time, date, exit = os.time, os.date, os.exit
local tinsert, explode = table.insert, seawolf.text.explode
local empty, ltrim = seawolf.variable.empty, seawolf.text.ltrim
local trim, dirname = seawolf.text.trim, seawolf.fs.dirname
local basename = seawolf.fs.basename
local rtrim, unescape = seawolf.text.rtrim, socket.url.unescape
local tconcat, lower = table.concat, string.lower

-- Output functions
-- Make sure to print headers on the first output
write = function (s)
  io.write = io_write
  write = io_write
  ophal.header:print()
  cgic.exit() -- free memory
  write "\n"
  write(s)
end
io.write = write

do
  local exit_orig = exit
  exit = function (code)
    os.exit = exit_orig
    exit = exit_orig
    ophal.header:print()
    cgic.exit() -- free memory
    exit_orig(code)
  end
  os.exit = exit
end

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

-- Headers handler
ophal.header = {
  sent = false,
  data = {
    -- Default headers
    ['content-type'] = {'text/html; charset=utf-8'},
    ['x-powered-by'] = {ophal.version},
  },
  set = function (t, header)
    local replace

    local name = header[1]
    local value = header[2]
    if header[3] ~= nil then
      replace = header[3]
    else
      replace = true
    end

    local headers = t.data

    if not empty(name) and type(name) == 'string' and
      (type(value) == 'string' or type(value) == 'number' or type(value) == 'function')
    then
      name = lower(name)
      if name == 'status' then
        replace = true -- always replace status header
      end
      if replace then
        headers[name] = {value}
      else
        if headers[name] == nil then
          headers[name] = {}
        end
        tinsert(headers[name], value)
      end
    end
  end,
  print = function (t)
    if not t.sent then
      for n, d in pairs(t.data) do
        for _, v in pairs(d) do
          if type(v) == 'function' then
            v()
          else
            io_write(([[%s: %s
]]):format(n, v))
          end
        end
      end
      t.sent = true
    end
  end
}

function header(...)
  ophal.header:set{...}
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

-- Load list of cookies
cgic.cookies(ophal.cookies)

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
      base_path() returns "/ophalfolder/".
    - http://example.com/path/alias (which is a path alias for article/306)
      returns "path/alias" as opposed to the internal path.
    - http://example.com/index.cgi returns an empty string, meaning: front page.
    - http://example.com/index.cgi?page=1 returns an empty string.

     Copied and adapted from Drupal 8.x request_path().
   ]]
  function request_path()
    local request_path, base_path_len, script

    if path ~= nil then
      return path
    end

    -- Get the part of the URI between the base path of the Drupal installation
    -- and the query string, and unescape it.
    request_path = request_uri(true)
    base_path_len = rtrim(dirname(_SERVER 'SCRIPT_NAME'), '\/'):len()
    path = unescape(request_path):sub(base_path_len + 1)

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
