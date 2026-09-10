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

--[[ A request with a session is about one visitor, and says so.

  `includes/http_cache.lua` disqualifies a response that carries a `Set-Cookie`,
  and that is not enough on its own: a signed-in request *resumes* a session, so
  the cookie was set at sign-in and this response emits none. The smoke suite
  caught it -- `db_author_frontpage_warm` came back marked `public` with an ETag,
  and the page is byte-for-byte the anonymous one, which is exactly why it had to
  be asserted rather than reasoned about. A validator built from projection
  versions describes the content, and content is not what makes a response
  personal.

  The session layer is what knows, so the session layer is what says it.
]]
local http_cache = require 'includes.http_cache'

--[[ This request's session, or nil before `session_init()` has run.

  Read on entry to each function rather than held in a file upvalue. The
  session belongs to the request that presented the cookie, and a worker that
  yields mid-request has more than one of those in flight; an upvalue here
  handed whichever request resumed the session of whichever request ran last.
]]
local function current_session()
  return ophal.session
end

-- Where a session id's data lives. Composed in one place because four callers
-- need it and a fifth would otherwise spell it a fifth way.
local function session_file_name(id)
  return format('%s/%s.ophal', sessions_path(), id)
end

--[[ Whether the server actually holds a session for this id.

  Read rather than stat'ed, because the caller that matters next wants the
  contents anyway and `io.open` answers both questions at once.
]]
local function session_file_exists(name)
  local fh = io.open(name, 'r')

  if fh == nil then
    return false
  end

  fh:close()
  return true
end

-- Session handler
if settings.sessionapi then
  if type(settings.sessionapi) ~= 'table' then
    settings.sessionapi = {enabled = true}
  end
end

--[[ Initialize session for the current request.

  Moved from module-level so that persistent runtimes re-read the session cookie
  on every request instead of only once.

  **A visitor who presents no session cookie is given no session here.** This
  used to mint an id and set the cookie unconditionally, and `session_start()`
  then opened a file for it, so every anonymous request created a session file
  and a lock file, wrote an empty table into one and removed the other -- about
  ten `open()` calls, measured in `tests/unit/test_session.lua`, on a request
  whose SQL budget is zero since stage 8.5. The file was left behind, so a
  crawler that never sends a cookie left one per request until cron's sweep
  reached them.

  The `Set-Cookie` was the more expensive half. A response carrying a
  per-visitor cookie can never be shared by a downstream cache whatever
  `Cache-Control` says, so this one line stood between the projection stack and
  every cache in front of it. That is why Phase 9 depends on Phase 7.

  Nothing is lost by waiting: a session that holds nothing is indistinguishable
  from no session. The id is minted at the first *write* into `_SESSION`, which
  is where a session starts meaning something.
]]
function session_init()
  local session_id = ophal.cookies['session-id'] or ''
  local resumed = uuid.isvalid(session_id)

  ophal.session = {
    id = resumed and session_id or nil,
    resumed = resumed,
    file = {},
  }
end

--[[ Give this request's session an id, a cookie and a file, now that it holds
  something.

  Called from the `__newindex` `session_start()` puts on an empty `_SESSION`, so
  the first assignment into the table pays for the session and every one after
  it is an ordinary rawset -- the metatable is dropped here rather than kept for
  the life of the request.

  A *read* deliberately does not reach this. `modules/user` asks every request
  for `_SESSION.user_id` and an anonymous visitor's answer is nil either way, so
  materializing on read would create a session for every visitor again and call
  it lazy.
]]
local function session_materialize()
  local session = current_session()
  local fh, sign, err

  if session == nil or session.open then
    return
  end

  if session.id == nil then
    session.id = random.uuid()
    cookie_set('session-id', session.id, 3*60*60, base.route, get_cookie_domain())
  end

  session.file.name = session_file_name(session.id)
  fh, sign, err = safe_open(session.file.name)
  fs_stats.record('open', nil, session.file.name, 'session')

  if not fh then
    error(format('session: cannot open session data: %s', tostring(err)))
  end

  fh:close()

  session.file.sign = sign
  session.open = true
  http_cache.disable()

  if getmetatable(_SESSION) ~= nil then
    setmetatable(_SESSION, nil)
  end

  session.data = _SESSION
end

-- An empty session table that pays for itself on first write. Reads see an
-- ordinary empty table, which is what an anonymous visitor's session is.
local function lazy_session_table()
  return setmetatable({}, {
    __newindex = function(t, key, value)
      session_materialize()
      rawset(t, key, value)
    end,
  })
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

  if not session then
    session_init()
    session = current_session()
  end

  local fh, sign, err, data, data_function, parsed

  --[[ A well-formed id the server holds no file for is not a session.

    `session_init()` knows only that the cookie parses as a uuid, and
    `safe_open()` below *creates* the file it fails to find -- so without this
    check any visitor could mint a session file, a lock file and an inode per
    request by presenting a random uuid, with cron's 24-hour sweep as the only
    reaper. That is an unauthenticated way to fill a filesystem.

    It closes session fixation at the root as well. An id Ophal never issued is
    now never adopted, so a value planted on a victim's browser is discarded
    here rather than carried until `session_regenerate()` rotates it at sign-in.
    That rotation still matters and is still tested: an attacker can ask the
    site for a real session and plant *that*, which this check cannot tell from
    a returning visitor.

    Demoting rather than erroring is deliberate. A session file also disappears
    because cron expired it, which is an ordinary returning visitor whose
    session has lapsed; they get a new one on their next write, exactly as a
    first-time visitor does.

    The cost is one `io.open` on requests that carry a cookie and none on
    requests that do not, so the anonymous budget is untouched.
  ]]
  if session.resumed and not session.open
    and not session_file_exists(session_file_name(session.id))
  then
    session.resumed = false
    session.id = nil
  end

  --[[ No cookie, so there is nothing to resume, nothing to lock and nothing to
    read. The table exists so that every reader keeps working -- `_SESSION` is
    an ordinary empty table to anyone who looks -- and the first write into it
    is what buys the id, the cookie and the file.

    The test was `not session.id` above, which is why this could not simply be
    left to fall through: a session with no id used to be impossible, and now it
    is the ordinary anonymous case.
  ]]
  if not session.resumed and not session.open then
    _SESSION = lazy_session_table()
    session.data = _SESSION
    return
  end

  -- Resuming a presented session is the signed-in case, among others.
  http_cache.disable()

  if not session.open then
    -- Compute session filename
    session.file.name = session_file_name(session.id)

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

  -- A session that was never materialized has no file and no lock, and
  -- `safe_close` would compose its lock name out of a nil.
  if not session or not session.open or session.file.name == nil then
    if session then
      session.open = false
    end
    _SESSION = nil
    return
  end

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

  if session.file.name ~= nil then
    os.remove(session.file.name)
    fs_stats.record('remove', nil, session.file.name, 'session')
  end

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
  session.file.name = session_file_name(session.id)
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

  -- The table carried over may be the lazy one, whose `__newindex`
  -- materializes. This session is materialized, so the hook has nothing left to
  -- do and would only run `session_materialize()` once more per key.
  if getmetatable(_SESSION) ~= nil then
    setmetatable(_SESSION, nil)
  end

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
