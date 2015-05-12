local io_write, buffer = io.write, env.output_buffer
local time, date, exit = os.time, os.date, os.exit
local tinsert, explode = table.insert, seawolf.text.explode
local empty, ltrim = seawolf.variable.empty, seawolf.text.ltrim
local trim, dirname = seawolf.text.trim, seawolf.fs.dirname
local basename = seawolf.fs.basename
local rtrim, unescape = seawolf.text.rtrim, socket.url.unescape
local tconcat, lower = table.concat, string.lower

ophal.raw_cookies = _SERVER 'HTTP_COOKIE'

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
  exit = function (code)
    os.exit = exit_orig
    exit = exit_orig
    ophal.header:print()
    exit_orig(code)
  end
  os.exit = exit
end

-- Headers handler
ophal.header = {
  sent = false,
  data = {},
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

--[[
 Redirect to raw destination URL. 
]]
function redirect(dest_url, http_response_code)
  header('status', http_response_code)
  header('location', dest_url)
  header('connection', 'close')
  write ''
end

function request_get_body()
  return io.read '*a'
end

function server_exit()
  os.exit()
end
