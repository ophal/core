local io_write, buffer = io.write, env.output_buffer
local time, date, exit = os.time, os.date, os.exit
local tinsert, explode = table.insert, seawolf.text.explode
local empty, ltrim = seawolf.variable.empty, seawolf.text.ltrim
local trim, dirname = seawolf.text.trim, seawolf.fs.dirname
local basename = seawolf.fs.basename
local rtrim, unescape = seawolf.text.rtrim, socket.url.unescape
local tconcat, lower = table.concat, string.lower

require 'cgic'
cgic.init()

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

-- Load list of cookies
local cookies, cookies_list = {}, {}
cgic.cookies(cookies)
for k, v in pairs(cookies) do
  cookies[k] = nil
  cookies_list[v] = true
end
setmetatable(cookies, {
  __index = function (t, k)
    return cookies_list[k] and cgic.cookieString(k, 255) or ''
  end
})
ophal.cookies = cookies

--[[
 Redirect to raw destination URL. 
]]
function redirect(dest_url, http_response_code)
  header('status', http_response_code)
  header('location', dest_url)
  header('connection', 'close')
  write ''
end

function headerCookieSetString(...)
  return cgic.headerCookieSetString(...)
end

function request_get_body()
  return io.read '*a'
end

