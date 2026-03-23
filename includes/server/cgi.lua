local io_write = io.write
local empty = seawolf.variable.empty
local lower = string.lower
local real_exit = os.exit
local tinsert = table.insert

local request_has_body = {
  POST = true,
  PUT = true,
  CONNECT = true,
  OPTIONS = true,
  PATCH = true,
}

local function request_headers()
  local headers = {}
  local known = {
    HTTP_HOST = 'Host',
    HTTP_COOKIE = 'Cookie',
    HTTP_IF_MODIFIED_SINCE = 'If-Modified-Since',
    HTTP_USER_AGENT = 'User-Agent',
    HTTP_ACCEPT = 'Accept',
    CONTENT_TYPE = 'Content-Type',
    CONTENT_LENGTH = 'Content-Length',
  }

  for key, header_name in pairs(known) do
    local value = _SERVER(key)
    if value ~= nil then
      headers[header_name] = value
    end
  end

  return headers
end

local header_state = {
  data = {},
  sent = false,
}

local function reset_headers()
  header_state.data = {}
  header_state.sent = false
end

local function print_headers()
  if not header_state.sent then
    for name, values in pairs(header_state.data) do
      for _, value in pairs(values) do
        if type(value) == 'function' then
          value = value()
        end
        io_write(('%s: %s\n'):format(name, value))
      end
    end
    header_state.sent = true
    return true
  end

  return false
end

local adapter = {}

function adapter.init()
  reset_headers()
end

function adapter.request()
  local method = _SERVER 'REQUEST_METHOD' or 'GET'
  local query_string = _SERVER 'QUERY_STRING' or ''
  local script_name = _SERVER 'SCRIPT_NAME' or '/index.cgi'
  local raw_cookies = _SERVER 'HTTP_COOKIE' or ''
  local uri = server_build_request_uri(_SERVER, script_name, query_string)

  return {
    method = method,
    scheme = (_SERVER 'HTTPS' == 'on') and 'https' or 'http',
    host = _SERVER 'HTTP_HOST' or _SERVER 'SERVER_NAME' or 'default',
    script_name = script_name,
    uri = uri,
    path = server_normalize_path(uri, script_name),
    query = server_parse_query(query_string),
    headers = request_headers(),
    cookies = server_parse_cookies(raw_cookies),
    body = request_has_body[method] and io.read '*a' or nil,
    raw_query = query_string,
    raw_cookies = raw_cookies,
  }
end

function adapter.header(name, value, replace)
  if replace == nil then
    replace = true
  end

  if not empty(name) and type(name) == 'string' and
    (type(value) == 'string' or type(value) == 'number' or type(value) == 'function')
  then
    name = lower(name)
    if name == 'status' then
      replace = true
    end

    if replace then
      header_state.data[name] = {value}
    else
      if header_state.data[name] == nil then
        header_state.data[name] = {}
      end
      tinsert(header_state.data[name], value)
    end
  end
end

function adapter.cookie(name, value, options)
  adapter.header('Set-Cookie', server_cookie_string(name, value, options), false)
end

function adapter.write(chunk)
  if print_headers() then
    io_write('\n')
  end
  io_write(tostring(chunk or ''))
end

function adapter.redirect(target, status)
  adapter.header('status', status or 302)
  adapter.header('location', target)
  adapter.header('connection', 'close')
end

function adapter.finish(status)
  if status ~= nil then
    adapter.header('status', status)
  end

  if print_headers() then
    io_write('\n')
  end
  return real_exit()
end

server_register_adapter('cgi', adapter)
