local temp_dir = seawolf.behaviour.temp_dir
local safe_open, safe_write = seawolf.fs.safe_open, seawolf.fs.safe_write
local safe_close, table_dump = seawolf.fs.safe_close, seawolf.contrib.table_dump
local time, rawset, tconcat = os.time, rawset, table.concat
local format, empty = string.format, seawolf.variable.empty

--[[ This request's session, or nil before `session_init()` has run.

  Read on entry to each function rather than held in a file upvalue. The
  session belongs to the request that presented the cookie, and a worker that
  yields mid-request has more than one of those in flight; an upvalue here
  handed whichever request resumed the session of whichever request ran last.
]]
local function current_session()
  return ophal.session
end

-- Session handler
if settings.sessionapi then
  if type(settings.sessionapi) ~= 'table' then
    settings.sessionapi = {enabled = true}
  end
end

-- Initialize session for the current request.
-- Moved from module-level so that persistent runtimes re-read
-- the session cookie on every request instead of only once.
function session_init()
  -- Look for session cookie
  local session_id = ophal.cookies['session-id'] or ''
  -- if session ID is not valid then set a new ID
  if not uuid.isvalid(session_id) then
    session_id = uuid.new()
    -- Delegate cookie header to ophal.header
    cookie_set('session-id', session_id, 3*60*60, base.route, get_cookie_domain())
  end
  -- init session table
  ophal.session = {
    id = session_id,
    file = {},
  }
end

-- Seed session state on module load; persistent runtimes reset it per request.
if settings.sessionapi then
  session_init()
end

function sessions_path()
  if settings.sessionapi then
    return settings.sessionapi.path or temp_dir()
  end

  return temp_dir()
end

-- Start new or resume existing session
function session_start()
  -- In persistent runtimes, session_init() is called by
  -- ophal_request_reset() before bootstrap phase 7.
  -- On first boot the module-level call above handles it.
  local session = current_session()

  if not session or not session.id then
    session_init()
    session = current_session()
  end

  local fh, sign, err, data, data_function, parsed

  if not session.open then
    -- Compute session filename
    session.file.name = string.format('%s/%s.ophal' , sessions_path(), session.id)

    -- Try to create/read session data
    fh, sign, err = safe_open(session.file.name)

    if fh then
      session.file.sign = sign
      -- Load session data
      session.open = true
      local data = fh:read('*a') or ''
      fh:close()
      if data:byte(1) == 27 then
        error 'session: binary bytecode in session data!'
      end

      -- Parse session data
      data_function, err = loadstring(data)
      if data_function then
        setfenv(data_function, {}) -- empty environment
        parsed, data, err = pcall(data_function)
      end
      if err then
        error(format('session: %s', err))
      end
      _SESSION = type(data) == 'table' and data or {}
      session.data = _SESSION
    else
      error "session: Can't load session data."
    end
  end
end

-- Reset runtime session data
local function session_close()
  local session = current_session()

  safe_close(session.file.name, session.file.sign)
  session.open = false
  _SESSION = nil
end

-- Write session data and end session
function session_write_close()
  local session = current_session()
  local serialized, rawdata, saved, err

  if session.open then
    rawdata = {'return '}
    serialized, err = pcall(table_dump, session.data, function (s) rawset(rawdata, #rawdata + 1, s) end)
    rawdata = tconcat(rawdata)
    if serialized then
      saved, err = safe_write(session.file.name, session.file.sign, rawdata)
      if not saved then
        error "session: Can't save session data!"
      end
    else
      error(format('session: %s', err))
    end
    session_close()
  end
end

-- Destroys all data registered to a session
function session_destroy()
  local session = current_session()

  session_close()
  os.remove(session.file.name)
  session.data = _SESSION -- global _SESSION is blank ATM
  session.id = nil
end

--[[ Move this session's data to a freshly generated id.

  Called when a session changes who it speaks for -- signing in, today. Without
  it the id that arrives on an anonymous request is the id that carries the
  authenticated one, which is session fixation: `session_init()` accepts any
  well-formed id the cookie presents, so anyone who can plant a `session-id` on
  a visitor's browser before they sign in holds their session afterwards.
  Cookie tossing from a neighbouring subdomain and plain http are both ways in;
  `HttpOnly` stops a script reading the cookie and does not stop one being set.

  The data table is carried over rather than rewritten, so a caller that has
  already put something in `_SESSION` does not lose it -- `auth_service()`
  assigns `user_id` right after this, and any module hooking `user_login`
  before it keeps what it wrote.

  The old file is removed rather than left to expire, so an id that has been
  rotated away from cannot be resumed: leaving it is the same fixation with a
  time limit on it.
]]
function session_regenerate()
  local session = current_session()
  local data, fh, sign, err

  if not session then
    return nil
  end

  data = _SESSION

  if session.open then
    safe_close(session.file.name, session.file.sign)
    session.open = false
  end

  if session.file.name then
    os.remove(session.file.name)
  end

  session.id = uuid.new()
  session.file = {}

  cookie_set('session-id', session.id, 3*60*60, base.route, get_cookie_domain())

  -- Reopened straight away so the lock this request holds is the new file's,
  -- and `session_write_close()` at the end of the request writes there.
  session.file.name = format('%s/%s.ophal', sessions_path(), session.id)
  fh, sign, err = safe_open(session.file.name)

  if not fh then
    error(format('session: cannot open regenerated session: %s',
      tostring(err)))
  end

  fh:close()

  session.file.sign = sign
  session.open = true
  _SESSION = type(data) == 'table' and data or {}
  session.data = _SESSION

  return session.id
end

-- Delete expired sessions
function session_destroy_expired()
  local path = sessions_path()

  for file in lfs.dir(path) do
    local session_file = file:sub(-6) == '.ophal'
    local lock_file = file:sub(-11) == '.ophal.lock'

    if session_file or lock_file then
      local filepath = path .. '/' .. file
      local attr = lfs.attributes(filepath)
      local age = os.difftime(os.time(), attr.change)

      if
        (session_file and age > (settings.sessionapi.ttl or 86400)) or
        (lock_file and age > (settings.sessionapi.lock_ttl or 120))
      then
        os.remove(filepath)
      end

    end
  end
end
