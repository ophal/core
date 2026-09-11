-- Unit tests for the session store's filesystem cost.

do
  local root = io.popen('pwd'):read('*l')
  local vendor_root = root .. '/tests/smoke/vendor'
  local vendor_share = vendor_root .. '/unpack/usr/share/lua/5.1'
  local vendor_lib = io.popen("find '" .. vendor_root .. "/unpack/usr/lib' -path '*/lua/5.1' -type d 2>/dev/null | sed -n '1p'"):read('*l')

  package.path = table.concat({
    root .. '/?.lua',
    root .. '/?/init.lua',
    vendor_root .. '/?.lua',
    vendor_root .. '/?/init.lua',
    vendor_share .. '/?.lua',
    vendor_share .. '/?/init.lua',
    package.path,
  }, ';')

  if vendor_lib and vendor_lib ~= '' then
    package.cpath = vendor_lib .. '/?.so;' .. package.cpath
  end
end

local lfs = require 'lfs'
local pass_count, fail_count = 0, 0

local function assert_eq(label, got, expected)
  if got == expected then
    pass_count = pass_count + 1
    io.write(('  ok %s\n'):format(label))
  else
    fail_count = fail_count + 1
    io.write(('  FAIL %s: expected %s, got %s\n'):format(
      label, tostring(expected), tostring(got)))
  end
end

local function make_temp_dir()
  local path = os.tmpname()
  os.remove(path)
  os.execute(("mkdir -p '%s'"):format(path))
  return path
end

--[[ What one session's filesystem traffic costs, measured rather than derived.

  `includes/session.lua` records one `open` for one logical session read, which
  is the operation rather than the syscall count. This measures the syscalls,
  because for six phases the number in that comment was one somebody derived by
  reading rather than one somebody counted -- and the derivation was wrong.

  Until 2026-09-10 this file measured `seawolf.fs`, which
  `includes/session/store.lua` replaced. Those numbers are worth keeping even
  though the code is gone, because they are what the store is an improvement
  *over*:

      safe_open        6 opens, 3 reads, 2 writes   (for one logical open)
      safe_write      +3 opens                      (it re-read the lock)
      safe_close      +1 remove                     (it re-read it again)

  Six, not five: reading the vendored source carefully gave five, and six is
  what it did. About ten `open()` per signed-in request, on a page whose SQL
  budget is zero.

  The store below is one open and one read to resume, one open and one rename to
  save, and no lock file in either direction.
]]
--[[ The same counting trick, for the store.

  `includes/session/store.lua` captures `io.open`, `os.rename` and `os.remove`
  as load-time locals, so the replacements have to be in place *before* the
  module is required -- exactly as `counted_fs()` does for `seawolf.fs`.
]]
local function counted_store()
  local counts = {open = 0, read = 0, write = 0, rename = 0, remove = 0}
  local real_open, real_rename, real_remove = io.open, os.rename, os.remove

  io.open = function(path, mode)
    counts.open = counts.open + 1

    local handle = real_open(path, mode)

    if handle == nil then
      return nil
    end

    return setmetatable({}, {
      __index = function(_, key)
        if key == 'read' then
          return function(_, ...)
            counts.read = counts.read + 1
            return handle:read(...)
          end
        elseif key == 'write' then
          return function(_, ...)
            counts.write = counts.write + 1
            return handle:write(...)
          end
        end

        return function(_, ...)
          return handle[key](handle, ...)
        end
      end,
    })
  end

  os.rename = function(from, to)
    counts.rename = counts.rename + 1
    return real_rename(from, to)
  end

  os.remove = function(path)
    counts.remove = counts.remove + 1
    return real_remove(path)
  end

  package.loaded['includes.session.store'] = nil

  return counts, function()
    io.open = real_open
    os.rename = real_rename
    os.remove = real_remove
    package.loaded['includes.session.store'] = nil
  end
end

io.write '\n-- and what the store that replaced it costs --\n'

--[[ The same measurement, on `includes/session/store.lua`, so the improvement
  is a diff between two rows of one report rather than a claim in a comment.

  The counter is the same `counted_fs()` harness: it replaces `io.open` and then
  loads the module, because the store captures `io.open`, `os.rename` and
  `os.remove` as load-time locals -- the convention this project adopted after
  being bitten by `module()` five times, and the thing that makes it measurable
  here.

  A resume is **one open and one read**, against six and three. A save is **one
  open and one rename**, against three opens for `safe_write` plus one remove
  for `safe_close`. And there is no lock file in either direction, which is the
  half that was never about speed.
]]
do
  local dir = make_temp_dir()
  local target = dir .. '/store.ophal'

  -- Something to resume, written before the counter is installed.
  do
    local seed = assert(io.open(target, 'w'))

    seed:write('{"user_id":7}')
    seed:close()
  end

  local counts, restore = counted_store()
  local store = require 'includes.session.store'
  local resumed = store.read(target)

  assert_eq('store_read_returns_the_session', (resumed or {}).user_id, 7)
  assert_eq('store_read_opens_once', counts.open, 1)
  assert_eq('store_read_reads_once', counts.read, 1)

  local before_open = counts.open
  local saved = store.write(target, {user_id = 8})

  assert_eq('store_write_saved', saved, true)
  assert_eq('store_write_opens_once', counts.open - before_open, 1)
  assert_eq('store_write_renames_once', counts.rename, 1)
  assert_eq('store_write_removes_nothing', counts.remove, 0)

  restore()

  -- No lock file, ever. That is the correctness half rather than the cost half:
  -- seawolf's lock raced on acquisition, blocked the worker in `socket.sleep`
  -- while it spun, and was reaped by cron on age alone while a request held it.
  local locks, temps = 0, 0

  for entry in lfs.dir(dir) do
    if entry:find('%.lock$') then
      locks = locks + 1
    elseif entry:find('%.tmp%.') then
      temps = temps + 1
    end
  end

  assert_eq('store_creates_no_lock_file', locks, 0)
  assert_eq('store_leaves_no_temp_file', temps, 0)

  -- And the write really landed.
  assert_eq('store_write_is_readable', (store.read(target) or {}).user_id, 8)

  os.execute(("rm -rf '%s'"):format(dir))
end

--[[ A session file written by an older Ophal holds Lua, not JSON.

  It has to read as *no session* rather than raise. `session_start()` used to
  `error()` on data it could not parse, which on an upgraded site is a 500 on
  every request presenting an old cookie -- everybody's first request after the
  deploy. Reading it as absent signs them out once instead.
]]
do
  local dir = make_temp_dir()
  local target = dir .. '/legacy.ophal'
  local store = require 'includes.session.store'
  local legacy = assert(io.open(target, 'w'))

  legacy:write('return {user_id = 7, csrf_token = "abc"}')
  legacy:close()

  assert_eq('a_lua_session_file_reads_as_no_session', store.read(target), nil)

  -- So does a truncated write, and so does an empty file.
  local partial = assert(io.open(target, 'w'))

  partial:write('{"user_id":')
  partial:close()

  assert_eq('a_truncated_session_file_reads_as_no_session',
    store.read(target), nil)

  local blank = assert(io.open(target, 'w'))

  blank:close()

  assert_eq('an_empty_session_file_reads_as_no_session', store.read(target), nil)

  os.execute(("rm -rf '%s'"):format(dir))
end

--[[ What the cron sweep costs, and that it reaps all three kinds of leftover.

  `TODO.md` has had `session_destroy_expired()` down as an optimization with no
  measurement behind it -- "it runs from cron, not from a page render", and
  Phase 7 changed its premise rather than its code: anonymous requests leave no
  session file at all now, so the directory it walks should be a fraction of
  what it was. The entry says to measure before optimizing, because the work may
  already have gone away. This is the measurement.

  It is also the first exercise the sweep's two newer classes have had. The
  store gave it `<id>.ophal.tmp.<hex>` and legacy `<id>.ophal.lock` to collect
  on 2026-09-10 and nothing has run either branch since.

  `lfs.attributes` is stubbed rather than the files being aged, because the
  sweep compares against `attr.change` -- the inode change time, which `touch`
  cannot backdate: any metadata write sets it to now. The stub is what makes an
  age a chosen value instead of a race. `lfs.dir` stays real, so the walk is
  over a real directory with real entries.
]]
do
  local dir = make_temp_dir()
  local real_lfs, real_remove, real_time = lfs, os.remove, os.time
  local now = real_time()
  local counts = {dir = 0, attributes = 0, remove = 0}

  -- name -> how many seconds old the sweep should think it is
  local ages = {}

  local function write_file(name, age)
    local handle = assert(io.open(dir .. '/' .. name, 'w'))

    handle:write('x')
    handle:close()
    ages[name] = age
  end

  -- Two live sessions and two past the TTL; one crashed write; one lock from
  -- before the store landed; and one file that is none of Ophal's business.
  write_file('11111111-1111-4111-8111-111111111111.ophal', 10)
  write_file('22222222-2222-4222-8222-222222222222.ophal', 10)
  write_file('33333333-3333-4333-8333-333333333333.ophal', 5000)
  write_file('44444444-4444-4444-8444-444444444444.ophal', 5000)
  write_file('55555555-5555-4555-8555-555555555555.ophal.tmp.a1b2c3d4', 5000)
  write_file('66666666-6666-4666-8666-666666666666.ophal.lock', 5000)
  write_file('notes.txt', 5000)

  _G.lfs = setmetatable({
    dir = function(path)
      counts.dir = counts.dir + 1
      return real_lfs.dir(path)
    end,
    attributes = function(path)
      counts.attributes = counts.attributes + 1
      return {mode = 'file', change = now - (ages[path:match('[^/]+$')] or 0)}
    end,
  }, {__index = real_lfs})

  os.remove = function(path)
    counts.remove = counts.remove + 1
    return real_remove(path)
  end
  os.time = function() return now end

  --[[ `session_init()` runs at the bottom of the file when `settings.sessionapi`
    is set, and it reads `ophal.cookies`. The sweep does not care, so the
    minimum that lets the file load is what is provided -- this is a test of
    one function, not of the session lifecycle.
  ]]
  _G.ophal = {cookies = {}}
  _G.settings = {sessionapi = {path = dir, ttl = 100}}
  dofile('includes/session.lua')
  session_destroy_expired()

  _G.lfs, os.remove, os.time = real_lfs, real_remove, real_time

  local function exists(name)
    return real_lfs.attributes(dir .. '/' .. name) ~= nil
  end

  --[[ The shape of the walk: **one `lfs.dir` and one stat per session-shaped
    entry**, and nothing for anything else. `.`, `..` and `notes.txt` are
    matched on their names and skipped without a syscall, which is what keeps
    the cost proportional to Ophal's own files rather than to the directory.

    Six of the seven files here are session-shaped, so six stats.
  ]]
  assert_eq('sweep_walks_the_directory_once', counts.dir, 1)
  assert_eq('sweep_stats_only_session_shaped_entries', counts.attributes, 6)
  -- Two expired sessions, one orphaned temp file, one legacy lock.
  assert_eq('sweep_removes_only_what_expired', counts.remove, 4)

  assert_eq('sweep_keeps_a_live_session',
    exists('11111111-1111-4111-8111-111111111111.ophal'), true)
  assert_eq('sweep_keeps_the_other_live_session',
    exists('22222222-2222-4222-8222-222222222222.ophal'), true)
  assert_eq('sweep_reaps_an_expired_session',
    exists('33333333-3333-4333-8333-333333333333.ophal'), false)

  -- The two classes the store added, neither of which had ever run.
  assert_eq('sweep_reaps_an_orphaned_temp_file',
    exists('55555555-5555-4555-8555-555555555555.ophal.tmp.a1b2c3d4'), false)
  assert_eq('sweep_reaps_a_legacy_lock_file',
    exists('66666666-6666-4666-8666-666666666666.ophal.lock'), false)

  -- And it is not a directory cleaner.
  assert_eq('sweep_leaves_a_foreign_file_alone', exists('notes.txt'), true)

  os.execute(("rm -rf '%s'"):format(dir))
end

io.write(('\n%d passed, %d failed\n'):format(pass_count, fail_count))
if fail_count > 0 then
  os.exit(1)
end
