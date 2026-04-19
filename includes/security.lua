local empty = seawolf.variable.empty

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

  if empty(token) and type(_GET) == 'table' then
    token = _GET.csrf_token
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
