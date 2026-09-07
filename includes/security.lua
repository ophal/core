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

--[[ Compare two strings without leaking where they differ.

  Every byte of the longer string is examined whether or not a mismatch has
  already been found, so the time taken depends on the lengths rather than on
  the position of the first difference. A length mismatch is folded into the
  same counter for the same reason.

  It lives here rather than in the module that first needed it because a second
  caller appeared: `modules/user` compares stored password hashes with it, and
  `cron_access()` below compares a shared secret. A secret comparison written
  twice is a secret comparison that will eventually be written once too naively.
]]
function secure_equals(left, right)
  local max_len, mismatch

  left, right = tostring(left or ''), tostring(right or '')
  max_len = #left
  mismatch = #left == #right and 0 or 1

  if #right > max_len then
    max_len = #right
  end

  for i = 1, max_len do
    if (left:byte(i) or 0) ~= (right:byte(i) or 0) then
      mismatch = mismatch + 1
    end
  end

  return mismatch == 0
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
  if type(log_warn) == 'function' then
    log_warn('CSRF validation failed', {
      event = 'csrf_denied',
      method = type(server_get_request) == 'function' and (server_get_request().method or nil) or nil,
      path = type(request_path) == 'function' and request_path() or nil,
    })
  end
  header('status', 401)
  if type(output) == 'table' then
    output.error = 'Invalid CSRF token.'
  end
  return false
end

--[[ The cron endpoint's shared secret, or nil when none is configured.

  `settings.cron.token` mirrors `vault.cron.token` the way `settings.site.hash`
  mirrors `vault.site.hash`, so the secret itself stays in the one file the
  project already treats as secret storage.
]]
function cron_token()
  local config = settings.cron
  local token = type(config) == 'table' and config.token or nil

  if type(token) ~= 'string' or token == '' then
    return nil
  end

  return token
end

local function cron_request_token()
  local token = type(_GET) == 'table' and _GET.token or nil

  if empty(token) then
    token = request_header('x-ophal-cron-token')
  end

  return token
end

--[[ Whether this request may run cron.

  The endpoint drains the deferred work queue, and that work is unbounded in the
  size of the tables it rebuilds, so an anonymous caller able to ask for it on
  demand is an amplifier. Two layers guard it: the `allow`/`deny` in the `/cron`
  location of `nginx.ophal.conf`, which holds even when Lua never gets to run,
  and this token, which is what protects a site whose cron runs from somewhere
  other than localhost.

  An unconfigured token warns and allows. Refusing instead would break the cron
  of every deployment that upgrades without editing its vault, and silently
  stopping a site's scheduled work is a worse failure than the one being
  prevented -- which the nginx default already covers. The warning is what makes
  the gap visible in the log rather than only in this comment.

  This lives beside `csrf_validate` rather than in a `includes/cron.lua` of its
  own because bootstrap requires this file from inside the jailed environment. A
  module required from `cron.lua` before `ophal.bootstrap()` would define its
  functions in the real globals table, where the bootstrapped callback cannot
  reach them.
]]
function cron_access()
  local expected = cron_token()

  if expected == nil then
    if type(log_warn) == 'function' then
      log_warn('cron endpoint has no token configured', {
        event = 'cron_token_missing',
      })
    end

    return true
  end

  return secure_equals(expected, cron_request_token() or '')
end

function cron_denied()
  if type(log_warn) == 'function' then
    log_warn('cron request denied', {
      event = 'cron_denied',
      path = type(request_path) == 'function' and request_path() or nil,
    })
  end

  header('status', 403)

  return false
end
