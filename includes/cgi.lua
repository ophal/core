local io_write, write, buffer = io.write, io.write, env.output_buffer
local time, date, exit = os.time, os.date, os.exit
local tinsert, explode = table.insert, seawolf.text.explode
local tconcat = table.concat

-- output functions
function print(s)
  write(tostring(s))
end

function echo(...)
  for _, v in pairs({...}) do
    write(tostring(v))
  end
end

-- Browser cache control
if settings.cache and _SERVER [[HTTP_IF_MODIFIED_SINCE]] ~= nil then
  print [[Status: 304 Not Modified
Cache-Control: must-revalidate

]]
  exit()
end

print(string.format([[Content-type: text/html; charset=utf-8
X-Powered-By: %s
Expires: Sun, 19 Nov 1978 05:00:00 GMT
Last-Modified: %s
Cache-Control: store, no-cache, must-revalidate, post-check=0, pre-check=0
Keep-Alive: timeout=15, max=90

]], ophal.version, date([[!%a, %d %b %Y %X GMT]], time(date([[*t]])) - 15*60)))

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
  for k, v in pairs(env.output_buffer) do
    output_buffer[k] = nil -- wipe buffer
  end
  -- turn off output buffering
  write = io_write
  settings.output_buffering = false
end

function output_get_clean()
  local output = tconcat(env.output_buffer)
  output_clean()
  return output
end

function output_flush()
  print(output_get_clean())
end
