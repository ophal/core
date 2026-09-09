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

  -- Compared the way every other secret in this file is compared. It was `==`,
  -- which returns as soon as two bytes differ; `secure_equals` is three lines
  -- away and `cron_access()` below already uses it. A CSRF token is a secret
  -- the client is supposed to echo back, so there is no reason for it to be
  -- the one comparison that leaks where it stopped matching.
  return type(_SESSION) == 'table' and
         not empty(token) and
         not empty(_SESSION.csrf_token) and
         secure_equals(token, _SESSION.csrf_token)
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

--[[ Whether a value is safe to use as one segment of a filesystem path.

  The upload endpoints take a filename, an upload id and a chunk index from the
  query string and interpolate all three into paths. Nothing downstream can
  undo that: by the time a path reaches `io.open` it is just a path, and
  `files/` lives under the document root that `nginx.ophal.conf` serves static
  extensions from directly. A caller holding `upload files` could therefore
  write anywhere in the served tree, which is a different privilege from the one
  the permission grants.

  The rule is deliberately "one segment or nothing" rather than a blocklist of
  dangerous sequences. A blocklist has to anticipate every encoding of "go up a
  level"; this accepts a name with no separator in it at all, which is the only
  shape any of these three values is ever supposed to have.

  Rejecting is the whole answer -- there is deliberately no sanitizing variant
  that strips the offending characters and continues. A repaired filename still
  writes a file, just not the one the caller asked for and not where they think,
  and a caller who did not mean to send `../` is not helped by having it removed
  silently.
]]
function safe_path_segment(value)
  local MAX = 255

  if type(value) ~= 'string' or value == '' or #value > MAX then
    return false
  end

  -- `.` and `..` traverse without containing a separator, so they have to be
  -- named. Any other leading dot is allowed: it is only a hidden file.
  if value == '.' or value == '..' then
    return false
  end

  -- A separator of either flavour, a NUL, or any other control byte. The NUL
  -- matters because the C library behind `io.open` stops there, so a name that
  -- looks long and harmless in Lua can open a shorter one on disk.
  if value:find('[/\\%z\1-\31]') then
    return false
  end

  return true
end

--[[ Refuse a request whose path segment could escape its directory. ]]
function unsafe_path_denied(output, name)
  if type(log_warn) == 'function' then
    log_warn('unsafe path segment rejected', {
      event = 'unsafe_path_segment',
      parameter = name,
      path = type(request_path) == 'function' and request_path() or nil,
    })
  end

  header('status', 400)

  if type(output) == 'table' then
    output.error = ('Invalid %s.'):format(name or 'parameter')
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
