--[[ Ophal's session file store: no lock, one rename, JSON on disk.

  This replaces `seawolf.fs`'s `safe_open` / `safe_write` / `safe_close`, and
  removing those is what lets **LuaSocket and luuid leave the dependency list**
  -- `seawolf/fs/init.lua`'s third line requires both at load, for a `sleep`
  that only the lock spin used.

  The lock was not merely slow. It was unsound in four separate ways:

  - **Acquisition raced.** It tested for the lock with `io.open(path)` and
    created it with `io.open(path, 'a+')` -- check-then-create, with no atomic
    exclusive mode. Two workers could both pass the test.
  - **The retry was recursion.** Up to 224 frames at 1 ms apiece, each blocking
    in LuaSocket's `socket.sleep`, which stops the whole worker rather than
    yielding the coroutine -- so one contended session stalled every other
    request that worker was serving. It ended in a hard `error()`, which is a
    500 rather than a wait.
  - **Cron deleted live locks.** `session_destroy_expired()` removed any `.lock`
    older than `lock_ttl` by **age alone**, ignoring the signature, so a request
    slower than 120 seconds had its lock reaped and another request took it.
  - **It cost about ten `open()` per request.** Six opens and three reads for
    one `safe_open`, plus three more across `safe_write` and `safe_close`,
    measured in `tests/unit/test_session.lua` against a counting `io.open`.

  What replaces it does not lock at all.

  **Writes are a temp file plus `os.rename`.** That is the primitive Phase 6
  already uses to finalize an upload: atomic within a filesystem, so a reader
  sees the old file or the new one and never a half-written one. Two concurrent
  writes to one session resolve last-writer-wins, which is a benign loss for
  what a session holds -- a user id, a CSRF token, flash messages -- and is
  strictly better than a design that can tear a write, stall a worker for a
  quarter of a second, wedge a session until cron runs, or hand one session to
  two writers because cron reaped the lock underneath them.

  **The file is JSON, not Lua.** It was `table_dump` output read back with
  `loadstring`, which is why `session_start()` carried a `data:byte(1) == 27`
  bytecode guard and set an empty environment before a `pcall`. A JSON parser
  needs none of that, and a session file stops being executable.

  **A file that will not decode is an empty session, never a raise.** Sessions
  written by an older Ophal hold Lua and will not parse. `session_start()` used
  to `error()` on unparseable data, which on an upgraded site is a 500 on every
  request presenting an old cookie. Everyone signs in again once; nobody sees a
  500.

  The rename cannot cross filesystems, so the temp file is written beside its
  target rather than in a temp directory -- the same constraint `INSTALL.md`
  records for uploads under "Uploads".
]]

local M = {}

local json = require 'includes.json'
local random = require 'includes.random'
local fs_stats = require 'includes.fs.stats'

--[[ Captured at load, like every other file in this project that has been
  bitten by the `module()` environment. This one does not call `module()`, but
  the convention has earned itself five times over.
]]
local io_open, os_rename, os_remove = io.open, os.rename, os.remove
local type, format = type, string.format

--[[ The session this path holds, or nil.

  nil covers every "there is no session here" case with one answer: no file, an
  unreadable file, an empty file, a file holding something that is not JSON, and
  a file holding JSON that is not an object. The caller mints a fresh session
  for all of them, which is the only useful thing to do with any of them.

  One `io.open` and one read. That is also the existence check
  `session_start()` used to make separately with an uncounted `io.open` before
  handing the same path to `safe_open`.
]]
function M.read(path)
  if type(path) ~= 'string' or path == '' then
    return nil
  end

  local handle = io_open(path, 'r')

  fs_stats.record('open', nil, path, 'session')

  if handle == nil then
    return nil
  end

  local data = handle:read('*a')

  handle:close()
  fs_stats.record('read', #(data or ''), path, 'session')

  if data == nil or data == '' then
    return nil
  end

  -- `json.decode` answers `nil, err` for anything it cannot use, including a
  -- document that parses but is not an object. Nothing here raises.
  return (json.decode(data))
end

--[[ Write `value` to `path` atomically. `true`, or `nil, err`.

  The temp name carries eight random bytes rather than a pid or a counter,
  because several workers write the same session and a name that two of them can
  choose at once is the thing being designed out.
]]
function M.write(path, value)
  if type(path) ~= 'string' or path == '' then
    return nil, 'session: no path to write to'
  end

  local encoded, err = json.encode(value or {})

  if encoded == nil then
    return nil, format('session: will not encode as JSON: %s', tostring(err))
  end

  local temp = format('%s.tmp.%s', path, random.hex(8))
  local handle

  handle, err = io_open(temp, 'w')
  fs_stats.record('open', nil, temp, 'session')

  if handle == nil then
    return nil, format('session: cannot write %s: %s', temp, tostring(err))
  end

  local written
  written, err = handle:write(encoded)
  handle:close()

  if not written then
    os_remove(temp)

    return nil, format('session: cannot write %s: %s', temp, tostring(err))
  end

  fs_stats.record('write', #encoded, path, 'session')

  local renamed
  renamed, err = os_rename(temp, path)

  if not renamed then
    -- Leave nothing behind for the cron sweep to find. A failed rename is a
    -- full disk or a crossed filesystem, not something to retry here.
    os_remove(temp)

    return nil, format('session: cannot rename %s to %s: %s',
      temp, path, tostring(err))
  end

  fs_stats.record('rename', nil, path, 'session')

  return true
end

--[[ Remove the session file at `path`. Absent is success. ]]
function M.remove(path)
  if type(path) ~= 'string' or path == '' then
    return
  end

  os_remove(path)
  fs_stats.record('remove', nil, path, 'session')
end

return M
