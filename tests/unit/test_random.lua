--[[ Unit tests for includes/random.lua, the one source of unguessable values.

  What is pinned here is mostly the *absence* of a weak path. The module
  replaced four generators -- session ids, CSRF tokens, password salts and the
  installer's site hash -- of which the last carried its own seed in its output
  and the other three rested on whichever generation mode the installed uuid
  binding happens to default to. So the assertions that matter are: it produces
  the shape callers depend on, distinct values, and an error rather than
  anything at all when no CSPRNG is available.
]]

package.path = './?.lua;./?/init.lua;' .. package.path

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

local function assert_truthy(label, value)
  assert_eq(label, not not value, true)
end

local function assert_raises(label, needle, fn, ...)
  local ok, err = pcall(fn, ...)

  if ok then
    fail_count = fail_count + 1
    io.write(('  FAIL %s: expected an error naming %q, got none\n'):format(
      label, needle))
  elseif not tostring(err):find(needle, 1, true) then
    fail_count = fail_count + 1
    io.write(('  FAIL %s: expected an error naming %q, got: %s\n'):format(
      label, needle, tostring(err)))
  else
    pass_count = pass_count + 1
    io.write(('  ok %s\n'):format(label))
  end
end

local random = require 'includes.random'

io.write '\n-- bytes --\n'

assert_eq('bytes_length', #random.bytes(16), 16)
assert_eq('bytes_one', #random.bytes(1), 1)
assert_eq('bytes_long', #random.bytes(256), 256)

assert_raises('bytes_rejects_zero', 'positive whole number', random.bytes, 0)
assert_raises('bytes_rejects_negative', 'positive whole number', random.bytes, -1)
assert_raises('bytes_rejects_fraction', 'positive whole number', random.bytes, 1.5)
assert_raises('bytes_rejects_text', 'positive whole number', random.bytes, 'lots')
assert_raises('bytes_rejects_nil', 'positive whole number', random.bytes, nil)

io.write '\n-- hex --\n'

assert_eq('hex_is_two_chars_per_byte', #random.hex(16), 32)
assert_truthy('hex_is_lowercase_hex', random.hex(32):match('^[0-9a-f]+$'))

io.write '\n-- uuid --\n'

do
  local value = random.uuid()

  -- The shape is what `session_init()` checks before accepting an id from the
  -- cookie, so a generator that produced anything else would have every
  -- request reject the cookie it had just set.
  assert_truthy('uuid_shape', value:match(
    '^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$'))
  assert_eq('uuid_length', #value, 36)

  -- RFC 4122: version nibble is 4, and the variant field is 10xx -- so the
  -- first character of the fourth group is one of 8, 9, a, b.
  assert_eq('uuid_version_is_4', value:sub(15, 15), '4')
  assert_truthy('uuid_variant_is_rfc4122', value:sub(20, 20):match('[89ab]'))
end

--[[ Distinctness is the property the whole module exists for.

  A generator seeded from the clock repeats within the second, which is exactly
  how long a burst of sign-ins takes. Two thousand is enough to catch that and
  small enough to stay fast; a real collision here would mean two visitors
  sharing a session.
]]
do
  local seen, count = {}, 0

  for _ = 1, 2000 do
    local value = random.uuid()

    if seen[value] == nil then
      seen[value] = true
      count = count + 1
    end
  end

  assert_eq('uuid_2000_distinct', count, 2000)
end

do
  local seen, count = {}, 0

  for _ = 1, 2000 do
    local value = random.hex(16)

    if seen[value] == nil then
      seen[value] = true
      count = count + 1
    end
  end

  assert_eq('hex_2000_distinct', count, 2000)
end

io.write '\n-- no source is an error, never a weak value --\n'

--[[ The point of the module, asserted directly.

  The generator this replaced fell back to `math.random` seeded with
  `os.time()`. Nothing downstream can tell a weak secret from a strong one, so
  the only safe behaviour with no CSPRNG available is to refuse -- an installer
  that fails is better than a site whose session ids are guessable.
]]
do
  local real_require, real_open = require, io.open

  random.reset()

  -- Both sources denied: no `resty.random`, no `/dev/urandom`.
  _G.require = function(name)
    if name == 'resty.random' then
      error('no resty here', 0)
    end

    return real_require(name)
  end

  io.open = function(path, mode)
    if path == '/dev/urandom' then
      return nil
    end

    return real_open(path, mode)
  end

  assert_raises('no_source_raises', 'no cryptographic random source',
    random.bytes, 16)
  assert_raises('no_source_raises_for_uuid', 'no cryptographic random source',
    random.uuid)

  _G.require = real_require
  io.open = real_open
  random.reset()

  -- And it recovers once a source is available again, rather than staying
  -- poisoned by the failed lookup.
  assert_eq('recovers_after_source_returns', #random.bytes(8), 8)
end

io.write(('\n%d passed, %d failed\n'):format(pass_count, fail_count))

if fail_count > 0 then
  os.exit(1)
end
