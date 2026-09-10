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

--[[ Load `seawolf.fs` against a counting `io.open`.

  It captures `open` at load time -- `local rename, remove, open = os.rename,
  os.remove, io.open` on line 4 of the vendored file -- so replacing `io.open`
  before the require is what gets the counter inside it. Nothing here stubs the
  filesystem: the calls are real, against a real temporary directory, and the
  counter only observes.
]]
local function counted_fs()
  local counts = {open = 0, read = 0, write = 0, remove = 0}
  local real_open, real_remove = io.open, os.remove

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

  os.remove = function(path)
    counts.remove = counts.remove + 1
    return real_remove(path)
  end

  package.loaded['seawolf.fs'] = nil
  package.loaded['seawolf'] = nil

  local fs = require 'seawolf.fs'

  return fs, counts, function()
    io.open = real_open
    os.remove = real_remove
  end
end

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

io.write '\n-- what one session open really costs --\n'

--[[ `includes/session.lua` records one `open` for one `safe_open`, and that is
  the logical operation rather than the syscall count. This measures the
  syscalls, so the comment there states a number somebody took rather than one
  somebody counted by reading.

  A fresh session has no lock file, so `safe_open` misses on it, creates it,
  writes a signature into it, and recurses to take the lock it just made before
  it ever touches the session file -- six `open()` calls and three reads for one
  logical open. The count is asserted rather than described because reading the
  vendored source gave five and six is what it does; the derivation is the thing
  that was wrong, which is the argument for the measurement.

  Every anonymous request paid this before Phase 7, on a page whose SQL budget
  is zero.
]]
do
  local dir = make_temp_dir()
  local fs, counts, restore = counted_fs()
  local target = dir .. '/fresh.ophal'
  local fh, sign = fs.safe_open(target)

  if fh then
    fh:close()
  end

  restore()

  assert_eq('safe_open_returns_a_handle', fh ~= nil, true)
  assert_eq('safe_open_signs_the_lock', type(sign) == 'string' and #sign > 0, true)
  -- The number the session comment cites.
  assert_eq('seawolf_safe_open_amplification', counts.open, 6)
  assert_eq('safe_open_reads_the_lock', counts.read, 3)
  assert_eq('safe_open_writes_the_signature', counts.write, 2)

  os.execute(("rm -rf '%s'"):format(dir))
end

--[[ And what the rest of one request's session traffic costs.

  `safe_write` reopens and re-reads the lock before writing the data, and
  `safe_close` reopens and re-reads it again before removing it. So a request
  that touches nothing pays three lock round trips, not one.
]]
do
  local dir = make_temp_dir()
  local fs, counts, restore = counted_fs()
  local target = dir .. '/whole.ophal'
  local fh, sign = fs.safe_open(target)
  local before_write, wrote, closed

  if fh then
    fh:read('*a')
    fh:close()
  end

  before_write = counts.open
  wrote = fs.safe_write(target, sign, 'return {}')
  closed = fs.safe_close(target, sign)

  restore()

  assert_eq('safe_write_saved', wrote, true)
  assert_eq('safe_close_unlocked', closed ~= nil and closed ~= false, true)
  assert_eq('safe_write_reopens_the_lock', counts.open - before_write, 3)
  assert_eq('safe_close_removes_the_lock', counts.remove, 1)

  os.execute(("rm -rf '%s'"):format(dir))
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

io.write(('\n%d passed, %d failed\n'):format(pass_count, fail_count))
if fail_count > 0 then
  os.exit(1)
end
