--[[ What a password digest costs, and whether the two implementations agree.

  Ophal hashes passwords by iterating a digest 10,000 times, and it resolved
  that digest through a chain of optional rocks -- `md5`, `sha1`, `lsha2`,
  `sha2` -- falling through to the pure-Lua `includes/sha256.lua` that ships
  with it. `README.md` said so as a feature: "no cryptography library is
  needed". It was never needed, because OpenResty has shipped `resty.sha256`
  the whole time and nothing asked it.

  So the shipped, documented, default configuration ran ten thousand rounds of
  interpreted SHA-256 inside a request. This file is the measurement that gates
  replacing it, and it is kept afterwards for the reason `json_bench.lua` is
  kept: the argument is only checkable with both implementations in front of
  you.

  Two questions.

  **What does it cost?** Timed at 1, 100 and 10,000 iterations, so the shape is
  visible as well as the total -- a per-call overhead that amortises would look
  different from a per-round cost that does not, and this is a per-round cost.
  The 10,000 number is the one that matters, because it is the default and
  nothing in the repo configures anything else.

  **Do they agree?** This is the half that gates the swap. `password_verify()`
  re-derives the *whole* stored string and `secure_equals` it, so a digest that
  differs by one nibble locks out every existing account on the site. The
  agreement is asserted over the real `password_digest` chain rather than over
  one call, because the chain feeds each round's hex output back in as the next
  round's input -- an implementation that disagreed only on, say, an empty
  input would still pass a single-shot comparison.

  Beside that, each of the six algorithms is checked against a published test
  vector. That is a different property and worth having separately: agreement
  says the two implementations match, a vector says the *mapping* is right --
  it is what catches `sha384` being wired to `resty.sha512`, which nothing in
  Ophal would otherwise notice, since no site configures those.

  Exits non-zero on any disagreement, for the reason `run_injection_probe.sh`
  already records: a harness that always exits 0 is a test that cannot fail the
  build.

  Run: bash tests/bench/run_digest_bench.sh
]]

package.path = './?.lua;./?/init.lua;' .. package.path

local ITERATIONS = tonumber(os.getenv('OPHAL_BENCH_ITERATIONS') or '') or 10000

local pure = require 'includes.sha256'
local resty_string = require 'resty.string'

local format, clock = string.format, os.clock

-- --------------------------------------------------------------- report ----

--[[ Somewhere for results to go.

  Same reason `json_bench.lua` and `layer_bench.lua` have one: LuaJIT deletes a
  loop whose result is never used.
]]
local sink = 0

local function consume(value)
  if type(value) == 'string' then
    sink = sink + #value
  elseif value then
    sink = sink + 1
  end
end

local pass_count, fail_count = 0, 0

local function assert_eq(label, got, expected)
  if got == expected then
    pass_count = pass_count + 1
    print(format('  ok %s', label))
  else
    fail_count = fail_count + 1
    print(format('  FAIL %s: expected %s, got %s',
      label, tostring(expected), tostring(got)))
  end
end

local function bench(iterations, fn)
  fn(1)

  local started = clock()

  for i = 1, iterations do
    consume(fn(i))
  end

  return (clock() - started) / iterations * 1e9
end

-- ------------------------------------------------------------ the digests --

--[[ The six OpenResty ships, by the names `settings.user.password_hash`
  accepts. Each is a constructor rather than a function, so a digest is
  new/update/final -- and `reset()` lets one object serve a whole iteration
  loop, which is what the loop below does.
]]
local RESTY_MODULES = {
  md5 = 'resty.md5',
  sha1 = 'resty.sha1',
  sha224 = 'resty.sha224',
  sha256 = 'resty.sha256',
  sha384 = 'resty.sha384',
  sha512 = 'resty.sha512',
}

local function resty_hex(algorithm, data)
  local implementation = require(RESTY_MODULES[algorithm])
  local state = implementation:new()

  state:update(data)

  return resty_string.to_hex(state:final())
end

--[[ Exactly what `password_digest()` in `modules/user/init.lua` does: the first
  round hashes `salt$password`, and every round after it hashes the previous
  round's *hex output* joined with the salt and the password again.

  It is a copy rather than a call, because `modules/user` calls `module()` and
  needs a booted environment that a bench has no business building. The copy
  measures the right *shape* -- a chain that feeds hex back in, which is where
  two implementations can diverge without a single-shot comparison noticing --
  but it cannot notice the real chain changing underneath it. What pins that is
  `versioned_hash_format` in `tests/unit/test_password_hashing.lua`, which
  matches the stored string, and `db_author_login`, which signs in for real.
]]
local function password_digest(digest_hex, password, salt, iterations)
  local digest = digest_hex('sha256', format('%s$%s', salt, password))

  for _ = 2, iterations do
    digest = digest_hex('sha256', format('%s$%s$%s', digest, salt, password))
  end

  return digest
end

local function pure_hex(_, data)
  return pure.hash256(data)
end

-- -------------------------------------------------------------- the timing --

local PASSWORD = 'smoke-author-pass'
local SALT = 'a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6'

print('')
print('digest backends -- password_digest, ns per whole call')
print('')
print(format('%-14s %18s %18s %10s', 'iterations', 'pure Lua', 'resty.sha256', 'ratio'))
print(('-'):rep(64))

local ROUNDS = {1, 100, ITERATIONS}

for _, rounds in ipairs(ROUNDS) do
  -- Few enough samples that the 10,000-round case does not take a minute, and
  -- enough that the one-round case is not a single clock tick.
  local samples = rounds >= 10000 and 3 or (rounds >= 100 and 200 or 20000)

  local pure_ns = bench(samples, function()
    return password_digest(pure_hex, PASSWORD, SALT, rounds)
  end)
  local resty_ns = bench(samples, function()
    return password_digest(resty_hex, PASSWORD, SALT, rounds)
  end)

  print(format('%-14d %18.1f %18.1f %9.1fx',
    rounds, pure_ns, resty_ns, pure_ns / resty_ns))
end

-- ---------------------------------------------------------- the assertions --

print('')
print('agreement -- the property that lets the swap keep every stored hash')
print('')

--[[ Over the chain, not over one call. Three rounds is enough to feed a hex
  output back in as an input twice, which is where the two could diverge
  without a single-shot comparison noticing.
]]
for _, rounds in ipairs({1, 2, 3, 17}) do
  assert_eq(
    format('password_digest_agrees_over_%d_rounds', rounds),
    password_digest(resty_hex, PASSWORD, SALT, rounds),
    password_digest(pure_hex, PASSWORD, SALT, rounds))
end

-- The empty string is the input a pure implementation is most likely to pad
-- wrongly, and `password_hash(nil)` reaches the digest as `salt$`.
assert_eq('sha256_agrees_on_the_empty_string',
  resty_hex('sha256', ''), pure_hex('sha256', ''))

-- A block boundary: SHA-256 pads to 64 bytes, so 55, 56 and 64 are where a
-- padding bug lives.
for _, length in ipairs({55, 56, 63, 64, 65}) do
  local data = ('x'):rep(length)

  assert_eq(format('sha256_agrees_at_%d_bytes', length),
    resty_hex('sha256', data), pure_hex('sha256', data))
end

print('')
print('vectors -- the property that says each name is wired to the right one')
print('')

--[[ Published digests of "abc", cross-checked against `openssl dgst` rather
  than against the bindings being tested. A vector taken from the thing under
  test proves only that it agrees with itself.
]]
local VECTORS = {
  {'md5', '900150983cd24fb0d6963f7d28e17f72'},
  {'sha1', 'a9993e364706816aba3e25717850c26c9cd0d89d'},
  {'sha224', '23097d223405d8228642a477bda255b32aadbce4bda0b3f7e36c9da7'},
  {'sha256', 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad'},
  {'sha384', 'cb00753f45a35e8bb5a03d699ac65007272c32ab0eded1631a8b605a43ff5bed'
    .. '8086072ba1e7cc2358baeca134c825a7'},
  {'sha512', 'ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a'
    .. '2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f'},
}

for _, vector in ipairs(VECTORS) do
  local algorithm, expected = vector[1], vector[2]

  assert_eq(format('%s_matches_its_published_vector', algorithm),
    resty_hex(algorithm, 'abc'), expected)
end

-- `password_hash_parse()` matches the stored digest with `[0-9a-fA-F]+` and
-- lowercases it, but `versioned_hash_format` in `test_password_hashing.lua`
-- pins lowercase on the way *out*. That is `to_hex`'s doing, so pin it here.
assert_eq('to_hex_is_lowercase',
  resty_string.to_hex('\170\187\204'), 'aabbcc')

-- The digest `tests/unit/test_cli.lua` pins for `ophal sha256 secret`, and the
-- one `seed_database.lua` writes as the seeded author's legacy password.
assert_eq('sha256_of_secret_is_the_seeded_legacy_hash',
  resty_hex('sha256', 'secret'),
  '2bb80d537b1da3e38bd30361aa855686bde0eacd7162fef6a25fe97bf527a25b')

print('')
print(format('%d passed, %d failed', pass_count, fail_count))
print(format('sink %d', sink))

if fail_count > 0 then
  os.exit(1)
end
