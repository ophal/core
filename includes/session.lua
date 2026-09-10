local temp_dir = require('includes.fs.path').temp_dir
local store = require 'includes.session.store'
local time, rawset = os.time, rawset
local format, empty = string.format, require('includes.util').empty
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

  if session == nil or session.open then
    return
  end

  if session.id == nil then
    session.id = random.uuid()
    cookie_set('session-id', session.id, 3*60*60, base.route, get_cookie_domain())
  end

  --[[ No file is created here, and that is the change.

    `safe_open()` stood here and its side effect was creating the session file
    before anything had been written into it -- which is also what made an
    unknown cookie id create one. The file now appears when
    `session_write_close()` renames it into place, so materializing costs
    nothing on disk and a request that writes and then fails leaves nothing
    behind.
  ]]
  session.file.name = session_file_name(session.id)
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


  --[[ A well-formed id the server holds no file for is not a session.

    `session_init()` knows only that the cookie parses as a uuid, and
    `safe_open()` used to *create* the file it failed to find -- so without this
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
  local resumed_data

  if session.resumed and not session.open then
    -- One read answers both questions: whether there is a session here, and
    -- what is in it. The separate existence probe this replaced was an
    -- `io.open` that no counter saw.
    session.file.name = session_file_name(session.id)
    resumed_data = store.read(session.file.name)

    if resumed_data == nil then
      session.resumed = false
      session.id = nil
      session.file.name = nil
    end
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

  --[[ The read already happened above, so this is only the handover.

    What stood here was `loadstring` on the file's contents with an empty
    environment and a `pcall`, guarded by a check for byte 27 -- Lua bytecode's
    signature -- because a session file was executable Lua. It is JSON now and
    none of that applies.

    A file that would not decode used to `error()`, which on a site upgrading
    from the Lua format is a 500 on every request carrying an old cookie.
    `store.read()` answers nil instead and the demotion above has already turned
    this request into a new session.
  ]]
  if not session.open then
    session.open = true
    _SESSION = resumed_data or {}
    session.data = _SESSION
  end
end

--[[ Reset runtime session data.

  There is no lock to release any more, so this drops the request's view of the
  session and nothing else. It used to `safe_close()`, which removed the lock
  file -- and that `remove` was counted against the session budget, which is why
  every measured session request showed one.
]]
local function session_close()
  local session = current_session()

  if session then
    session.open = false
  end

  _SESSION = nil
end

--[[ Write session data and end the session.

  One `io.open`, one write and one `os.rename` through
  `includes/session/store.lua`. It was a `table_dump` into a `'return '`-prefixed
  string handed to `safe_write`, which reopened and re-read the lock before
  writing -- three more `open()` calls to check a lock this request already
  held.
]]
function session_write_close()
  local session = current_session()

  if not session or not session.open then
    return
  end

  local saved, err = store.write(session.file.name, session.data)

  if not saved then
    error(format('session: %s', tostring(err)))
  end

  session_close()
end

-- Destroys all data registered to a session
function session_destroy()
  local session = current_session()

  session_close()

  store.remove(session.file.name)

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

  if not session then
    return nil
  end

  local data = _SESSION

  if session.file.name then
    store.remove(session.file.name)
  end

  session.id = random.uuid()
  session.file = {}
  session.open = false

  cookie_set('session-id', session.id, 3*60*60, base.route, get_cookie_domain())

  -- Named but not created. `session_write_close()` writes it at the end of the
  -- request; there is no lock to take, so there is nothing to open here.
  session.file.name = session_file_name(session.id)
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
--[[ The cron sweep, over three kinds of leftover.

  `<id>.ophal` on `settings.sessionapi.ttl`, as before.

  `<id>.ophal.tmp.<hex>` from a write that died between `io.open` and
  `os.rename`. `store.write()` removes its own temp file on every failure it can
  see, so this only catches a worker killed mid-write. A short TTL, because a
  temp file older than a few minutes cannot belong to a request still running.

  `<id>.ophal.lock` from before this release, so an upgraded site sweeps itself
  clean. `settings.sessionapi.lock_ttl` is inert now -- nothing takes a lock --
  but the key is still read here and still accepted in a settings file rather
  than being an error, because erroring on a key that used to be valid is a
  worse upgrade than ignoring it.
]]
local TEMP_TTL = 600

function session_destroy_expired()
  local path = sessions_path()

  for file in lfs.dir(path) do
    local lock_file = file:sub(-11) == '.ophal.lock'
    local temp_file = file:find('%.ophal%.tmp%.%x+$') ~= nil
    local session_file = not lock_file and not temp_file
      and file:sub(-6) == '.ophal'

    if session_file or lock_file or temp_file then
      local filepath = path .. '/' .. file
      local attr = lfs.attributes(filepath)
      local age = attr and os.difftime(os.time(), attr.change) or 0

      if
        (session_file and age > (settings.sessionapi.ttl or 86400)) or
        (lock_file and age > (settings.sessionapi.lock_ttl or 120)) or
        (temp_file and age > TEMP_TTL)
      then
        os.remove(filepath)
      end
    end
  end
end
