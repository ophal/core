local empty = seawolf.variable.empty
local ngx_print, ngx_var, ngx_req = ngx.print, ngx.var, ngx.req
local HTTP_OK = ngx.HTTP_OK or 200
local HTTP_MOVED_TEMPORARILY = ngx.HTTP_MOVED_TEMPORARILY or 302
local lower = string.lower
local tinsert = table.insert

local request_has_body = {
  POST = true,
  PUT = true,
  CONNECT = true,
  OPTIONS = true,
  PATCH = true,
}

env._SERVER = function (v)
  local headers

  if v == 'QUERY_STRING' then
    return ngx_var.args
  elseif v == 'REQUEST_URI' then
    return ngx_var.request_uri or ngx_var.uri
  elseif v == 'SCRIPT_NAME' then
    return ngx_var.script_name or '/index.cgi'
  elseif v == 'HTTP_HOST' then
    headers = ngx_req.get_headers()
    return headers.Host or headers.host or ngx_var.host
  elseif v == 'SERVER_NAME' then
    return ngx_var.server_name
  elseif v == 'HTTPS' then
    return ngx_var.scheme == 'https' and 'on' or nil
  else
    return ngx_var[v:lower()]
  end
end

local function request_body(method)
  local body, file_name, handle

  if not request_has_body[method] then
    return nil
  end

  ngx_req.read_body()
  body = ngx_req.get_body_data()
  if body ~= nil then
    return body
  end

  file_name = ngx_req.get_body_file()
  if file_name then
    handle = io.open(file_name)
    if handle then
      body = handle:read '*a'
      handle:close()
      return body
    end
  end

  return ''
end

local adapter = {}

function adapter.request()
  local headers = ngx_req.get_headers()
  local method = ngx_req.get_method()
  local query_string = ngx_var.args or ''
  local script_name = env._SERVER('SCRIPT_NAME') or '/index.cgi'
  local uri = server_build_request_uri(env._SERVER, script_name, query_string)
  local raw_cookies = headers.Cookie or headers.cookie or ''

  return {
    method = method,
    scheme = ngx_var.scheme or 'http',
    host = env._SERVER('HTTP_HOST') or env._SERVER('SERVER_NAME') or 'default',
    script_name = script_name,
    uri = uri,
    path = server_normalize_path(uri, script_name),
    query = server_parse_query(query_string),
    headers = headers,
    cookies = server_parse_cookies(raw_cookies),
    body = request_body(method),
    raw_query = query_string,
    raw_cookies = raw_cookies,
  }
end

function adapter.header(name, value, replace)
  local current

  if empty(name) or value == nil then
    return
  end

  if type(value) == 'function' then
    value = value()
  end

  if lower(name) == 'status' then
    value = server_parse_status(value)
    if value ~= nil then
      ngx.status = value
    end
    return
  end

  if replace == nil then
    replace = true
  end

  if replace then
    ngx.header[name] = value
  else
    current = ngx.header[name]
    if current == nil then
      ngx.header[name] = value
    elseif type(current) == 'table' then
      tinsert(current, value)
      ngx.header[name] = current
    else
      ngx.header[name] = {current, value}
    end
  end
end

function adapter.cookie(name, value, options)
  adapter.header('Set-Cookie', server_cookie_string(name, value, options), false)
end

function adapter.write(chunk)
  ngx_print(tostring(chunk or ''))
end

function adapter.redirect(target, status)
  adapter.header('status', status or HTTP_MOVED_TEMPORARILY)
  adapter.header('location', target)
end

function adapter.finish(status)
  local final_status = server_parse_status(status) or ngx.status or HTTP_OK

  if final_status == 0 then
    final_status = HTTP_OK
  end

  if status ~= nil then
    adapter.header('status', status)
  end

  return ngx.exit(final_status)
end

server_register_adapter('nginx', adapter)
