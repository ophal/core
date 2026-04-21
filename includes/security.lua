local empty = seawolf.variable.empty
local lower = string.lower

local function request_header(name)
  local request = type(server_get_request) == 'function' and server_get_request()
  local headers = request and request.headers or {}
  local wanted = lower(name)

  return headers[name] or headers[wanted] or (function()
    for k, v in pairs(headers) do
      if lower(k) == wanted then
        return v
      end
    end
  end)()
end

local function form_body_token()
  local content_type = request_header('content-type') or ''

  if
    type(request_get_body) == 'function' and
    type(server_parse_query) == 'function' and
    content_type:find('application/x-www-form-urlencoded', 1, true)
  then
    local data = server_parse_query(request_get_body() or '')
    return data.csrf_token or data.csrfToken
  end
end

function csrf_enabled()
  local config = settings.csrf

  if config == false then
    return false
  elseif type(config) == 'table' and config.enabled == false then
    return false
  end

  return settings.sessionapi ~= nil
end

function csrf_token()
  if not csrf_enabled() or type(_SESSION) ~= 'table' then
    return nil
  end

  if empty(_SESSION.csrf_token) then
    _SESSION.csrf_token = uuid.new()
  end

  return _SESSION.csrf_token
end

function csrf_validate(token)
  if not csrf_enabled() then
    return true
  end

  return type(_SESSION) == 'table' and
         not empty(token) and
         token == _SESSION.csrf_token
end

function csrf_validate_request(data)
  local token

  if type(data) == 'table' then
    token = data.csrf_token or data.csrfToken
  end

  if empty(token) then
    token = request_header('x-csrf-token')
  end

  if empty(token) and type(_GET) == 'table' then
    token = _GET.csrf_token
  end

  if empty(token) then
    token = form_body_token()
  end

  return csrf_validate(token)
end

function csrf_denied(output)
  header('status', 401)
  if type(output) == 'table' then
    output.error = 'Invalid CSRF token.'
  end
  return false
end
