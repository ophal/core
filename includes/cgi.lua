local io_write, write, buffer = io.write, io.write, env.output_buffer
local time, date, exit = os.time, os.date, os.exit
local tinsert, explode = table.insert, seawolf.text.explode
local empty = seawolf.variable.empty
local tconcat, lower = table.concat, string.lower

-- Output functions
-- Make sure to print headers on the first output
write = function (s)
  io.write = io_write
  write = io_write
  ophal.header:print()
  write "\n"
  write(s)
end
io.write = write

do
  local exit_orig = exit
  exit = function ()
    os.exit = exit_orig
    exit = exit_orig
    ophal.header:print()
    exit_orig()
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
    [ [[content-type]]] = {[[text/html; charset=utf-8]]},
    [ [[x-powered-by]]] = {ophal.version},
  },
  set = function (t, header)
    local name = header[1]
    local value = header[2]
    if header[3] ~= nil then
      replace = header[3]
    else
      replace = true
    end

    local headers = t.data

    if not empty(name) and type(value) == [[string]]  and type(name) == [[string]] then
      name = lower(name)
      if name == [[status]] then
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
          io_write(([[%s: %s
]]):format(n, v))
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
if settings.cache and _SERVER [[HTTP_IF_MODIFIED_SINCE]] ~= nil then
  header([[status]], [[304 Not Modified]])
  header([[cache-control]], [[must-revalidate]])
  exit()
end

-- Redirect to mobile domain name
if settings.mobile then
  local domain_name = settings.mobile.domain_name
  if settings.mobile.redirect and mobile.detect.isMobile() and _SERVER [[HTTP_HOST]] ~= domain_name then
    header([[Location]], [[http://]] .. domain_name)
    print(([[Redirecting to <a href="http://%s">http://%s</a>.]]):format(domain_name, domain_name))
    os.exit()
  end
end

-- Session handler
if settings.sessionapi then
  -- Look for session cookie
  cgic.cookies(ophal.cookies)
  local session_id = cgic.cookieString([[session-id]], 36)
  -- if session ID is not valid then set a new ID
  if not uuid.isvalid(session_id) then
    session_id = uuid.new()
    -- Print session cookie header (directly, not handled by ophal.header)
    cgic.headerCookieSetString([[session-id]], session_id,
      60*60*24*365*12, base_path, _SERVER [[SERVER_NAME]] or [[]])
  end
  -- free CGI memory
  cgic.exit()
end

-- Set headers for dynamic content
header([[expires]], [[Sun, 19 Nov 1978 05:00:00 GMT]])
header([[last-modified]], date([[!%a, %d %b %Y %X GMT]], time(date([[*t]])) - 15*60))
header([[cache-control]], [[store, no-cache, must-revalidate, post-check=0, pre-check=0]])
header([[Keep-Alive]], [[timeout=15, max=90]])

-- Parse query string
require [[socket.url]]
local unescape = socket.url.unescape
local list = explode([[&]], _SERVER [[QUERY_STRING]] or [[]])
local parsed = {}
if list then
  local tmp, key, value
  for _, v in pairs(list) do
    if #v > 0 then
      tmp = explode([[=]], v)
      key = unescape((tmp[1] or [[]]):gsub([[+]], [[ ]]))
      value = unescape((tmp[2] or [[]]):gsub([[+]], [[ ]]))
      parsed[key] = value
    end
  end
end
_GET = parsed

-- output buffering
do
  local write_orig = write
  if settings.output_buffering then
    write = function (s)
      local type_ = type(s)
      if type_ ~= [[string]] then
        s = ([[(%s)]]):format(type_)
      end
      tinsert(buffer, #buffer + 1, s)
    end
  end

  function output_clean()
    for k, v in pairs(buffer) do
      buffer[k] = nil -- wipe buffer
    end
    -- restore output function
    write = write_orig
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
