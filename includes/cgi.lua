local write, time, date, exit = io.write, os.time, os.date, os.exit
local explode = seawolf.text.explode

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
