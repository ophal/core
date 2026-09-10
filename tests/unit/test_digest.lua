--[[ The digest layer's contract, against the real bindings.

  `includes/digest.lua` runs against the `resty.*` modules the worker loads, not
  a stand-in, for the reason `test_json.lua` records: the suite moved onto
  LuaJIT so that the library under test is the one production uses.

  What is pinned here is the *contract* -- the algorithm names accepted, the
  case of the output, and what an unknown name does. The property that the
  digests match the pure-Lua implementation they replaced lives in
  `tests/bench/digest_bench.lua`, because it needs both implementations and the
  retired one is not part of Ophal any more.
]]

local digest = require 'includes.digest'

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

io.write('test_digest\n')

io.write '\n-- every algorithm Ophal names --\n'

--[[ Digests of "abc", cross-checked against `openssl dgst` rather than against
  the bindings under test. `settings.user.password_hash.algorithm` accepts each
  of these names, so each has to reach the implementation it names -- and
  nothing else in the suite would notice `sha384` wired to `resty.sha512`,
  because no profile configures either.
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
  assert_eq(('%s_hashes_abc'):format(vector[1]),
    digest.hex(vector[1], 'abc'), vector[2])
end

io.write '\n-- the output shape callers depend on --\n'

--[[ Lowercase, and `versioned_hash_format` in `test_password_hashing.lua`
  pins it from the other side by matching the stored string with `[0-9a-f]+`.
  Every hash already written to a database is lowercase, so this is a
  compatibility property rather than a style one.
]]
assert_eq('hex_is_lowercase',
  digest.hex('sha256', 'abc'), digest.hex('sha256', 'abc'):lower())

assert_eq('sha256_is_64_characters', #digest.hex('sha256', 'abc'), 64)

--[[ `password_hash(nil)` reaches the digest as `salt$`, and
  `password_legacy_hash(nil)` reaches it as the empty string. Neither should
  raise -- the sign-in service answers a bad body with 400 rather than a 500.
]]
assert_eq('nil_data_hashes_as_the_empty_string',
  digest.hex('sha256', nil), digest.hex('sha256', ''))

assert_eq('empty_string_has_a_digest',
  digest.hex('sha256', ''),
  'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855')

io.write '\n-- an algorithm Ophal cannot hash with --\n'

--[[ The old chain answered an unknown name with
  `error('[user] unknown hash algorithm "%s"')` from inside the module, after a
  request had already reached it. This says the same thing sooner and names the
  set, so a typo in `settings.user.password_hash.algorithm` is legible.
]]
local ok, err = pcall(digest.hex, 'sha3', 'abc')

assert_eq('unknown_algorithm_raises', ok, false)
assert_eq('unknown_algorithm_names_the_algorithm',
  tostring(err):find('sha3', 1, true) ~= nil, true)
assert_eq('unknown_algorithm_names_the_supported_set',
  tostring(err):find('sha256', 1, true) ~= nil, true)

--[[ No file and line in the message. `error(msg, 0)` is what does it, and it
  matters because `route_execute_callback`'s pcall turns a raise into a string
  that `theme.json` renders into the response body -- the disclosure
  `assert_no_source_path` exists to catch.
]]
assert_eq('unknown_algorithm_carries_no_source_path',
  tostring(err):find('%.lua:%d') == nil, true)

io.write '\n-- supports() --\n'

assert_eq('supports_sha256', digest.supports('sha256'), true)
assert_eq('supports_md5', digest.supports('md5'), true)
assert_eq('does_not_support_sha3', digest.supports('sha3'), false)
assert_eq('does_not_support_nil', digest.supports(nil), false)

io.write(('\n%d passed, %d failed\n'):format(pass_count, fail_count))

if fail_count > 0 then
  os.exit(1)
end
