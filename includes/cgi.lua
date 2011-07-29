require [[socket.url]]
local write, unescape, trim, dirname = io.write, socket.url.unescape, seawolf.text.trim, seawolf.filesystem.dirname

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

-- Create base URL
base_root = (_SERVER [[HTTPS]] ~= nil and _SERVER [[HTTPS]] == [[on]]) and [[https]] or [[http]]
base_root = base_root .. '://' .. (_SERVER [[HTTP_HOST]] or [[]])
base_url = base_root

local dir = trim(dirname(_SERVER [[SCRIPT_NAME]] or [[]]), [[\,/]])
if dir ~= [[]] then
  base_path = [[/]] .. dir
  base_url = base_url .. base_path
  base_path = base_path .. [[/]]
else
  base_path = [[/]]
end
