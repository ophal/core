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

io.write(('\n%d passed, %d failed\n'):format(pass_count, fail_count))
if fail_count > 0 then
  os.exit(1)
end
