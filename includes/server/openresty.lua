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
    return ngx_var.ophal_script_name or '/index.lua'
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

--[[ Where nginx put the request body, when it put it in a file.

  nginx buffers a body larger than `client_body_buffer_size` to disk on its own.
  Reading it back into a Lua string is then a second full copy of something the
  kernel has already written, and for an upload that copy is the whole point of
  the request. A caller that only wants to move the bytes somewhere -- which is
  exactly what an upload does -- can take this path and rename the file instead.

  nil when the body is small enough to have stayed in memory, which is the
  ordinary case for every non-upload request, and nil for methods that carry no
  body at all.
]]
local function request_body_file(method)
  if not request_has_body[method] then
    return nil
  end

  ngx_req.read_body()

  return ngx_req.get_body_file()
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
  local script_name = env._SERVER('SCRIPT_NAME') or '/index.lua'
  local uri = server_build_request_uri(env._SERVER, script_name, query_string)
  local raw_cookies = headers.Cookie or headers.cookie or ''
  local request

  request = {
    method = method,
    scheme = ngx_var.scheme or 'http',
    host = env._SERVER('HTTP_HOST') or env._SERVER('SERVER_NAME') or 'default',
    script_name = script_name,
    uri = uri,
    path = server_normalize_path(uri, script_name),
    query = server_parse_query(query_string),
    headers = headers,
    cookies = server_parse_cookies(raw_cookies),
    body_file = request_body_file(method),
    raw_query = query_string,
    raw_cookies = raw_cookies,
  }

  --[[ `body` is materialised on first read, not here.

    Reading it eagerly meant every spilled body was copied into a Lua string
    whether anything wanted the string or not -- and the one caller that never
    does is the upload endpoint, whose whole job is to move those bytes to
    another file. `request_get_body()` is the only consumer of this field in the
    codebase, so the laziness is invisible everywhere else; the value is cached
    on the table by the first read, so it is still read once per request.
  ]]
  return setmetatable(request, {
    __index = function(t, key)
      if key ~= 'body' then
        return nil
      end

      local value = request_body(method)

      rawset(t, 'body', value)

      return value
    end,
  })
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

--[[ What has been set on the response so far.

  `includes/http_cache.lua` has to know two things before the first byte goes
  out: what status this response carries, and whether anything has put a cookie
  on it. Both live in the runtime rather than in Ophal -- `adapter.header()`
  writes straight into `ngx.header` and `ngx.status` -- so they are read back
  through the adapter for the same reason they are written through it.
]]
function adapter.status()
  local status = tonumber(ngx.status)

  if status == nil or status == 0 then
    return HTTP_OK
  end

  return status
end

function adapter.header_get(name)
  return ngx.header[name]
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

server_register_adapter('openresty', adapter)
