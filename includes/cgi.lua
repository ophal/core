require [[socket/url]]
local write, unescape = io.write, socket.url.unescape

-- Parse query string
local function split(s, sep)
  sep = lpeg.P(sep)
  local elem = lpeg.C((1 - sep)^0)
  local p = lpeg.Ct(elem * (sep * elem)^0)
  return lpeg.match(p, s)
end
local list = split(os.getenv [[QUERY_STRING]] or [[]], [[&]])
local parsed = {}
if list then
  local tmp, key, value
  for _, v in pairs(list) do
    if #v > 0 then
      tmp = split(v, [[=]])
      key = unescape(tmp[1]:gsub([[+]], [[ ]]))
      value = unescape(tmp[2]:gsub([[+]], [[ ]]))
      parsed[key] = value
    end
  end
end
_GET = parsed

-- output functions
function print(s)
  write(tostring(s))
end

function echo(...)
  for _, v in pairs({...}) do
    write(tostring(v))
  end
end
