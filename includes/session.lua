local temp_dir = seawolf.behaviour.temp_dir
local safe_open, safe_write = seawolf.fs.safe_open, seawolf.fs.safe_write
local safe_close, table_dump = seawolf.fs.safe_close, seawolf.contrib.table_dump
local time, rawset, tconcat = os.time, rawset, table.concat
local format, empty = string.format, seawolf.variable.empty
--[[ Session ids come from the CSPRNG, not from `uuid.new()`.

  `uuid` here is whatever binding is installed -- production is told to install
  `luuid`, over libuuid, which can generate time-and-MAC based UUIDs as well as
  random ones, and which of those `new()` returns is that library's default
  rather than this project's choice. A session id is the credential for a whole
  session, so it is generated from a source this codebase knows the strength
  of. `uuid.isvalid()` still gates what arrives in the cookie, and
  `random.uuid()` produces the same 8-4-4-4-12 shape so that check is unchanged.
]]
local random = require 'includes.random'

--[[ The session path is the second caller of `includes/fs/stats.lua`.

  That module's own header says it is deliberately not global instrumentation --
  only the media path calls through it, because that was the only path with a
  budget to hold. The session path has one now: an anonymous request costs zero
  queries since stage 8.5 and its filesystem cost had never been counted at all,
  which is the whole reason it survived six phases of measurement.

  What is recorded here is the *logical* operation -- one `open` for one
  `safe_open`. Underneath each is worth far more, and the multiplier was
  measured rather than read off the source: `tests/unit/test_session.lua` counts
  a real `io.open` through the vendored `seawolf.fs` and gets **six opens and
  three reads for one `safe_open`**, plus three more opens across the
  `safe_write` and `safe_close` that end the request. Reading the code carefully
  gave five, which is the argument for having measured it.

  So the four operations this file records are about ten `open()` calls, on a
  request whose SQL budget is zero.
]]
local fs_stats = require 'includes.fs.stats'

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
    session_id = random.uuid()
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
    fs_stats.record('open', nil, session.file.name, 'session')

    if fh then
      session.file.sign = sign
      -- Load session data
      session.open = true
      local data = fh:read('*a') or ''
      fh:close()
      fs_stats.record('read', #data, session.file.name, 'session')
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
  fs_stats.record('remove', nil, session.file.name, 'session')
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
      fs_stats.record('write', #rawdata, session.file.name, 'session')
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
  fs_stats.record('remove', nil, session.file.name, 'session')
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
    fs_stats.record('remove', nil, session.file.name, 'session')
  end

  session.id = random.uuid()
  session.file = {}

  cookie_set('session-id', session.id, 3*60*60, base.route, get_cookie_domain())

  -- Reopened straight away so the lock this request holds is the new file's,
  -- and `session_write_close()` at the end of the request writes there.
  session.file.name = format('%s/%s.ophal', sessions_path(), session.id)
  fh, sign, err = safe_open(session.file.name)
  fs_stats.record('open', nil, session.file.name, 'session')

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
