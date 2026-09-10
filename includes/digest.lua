--[[ One digest layer, over OpenResty's bundled SHA-2 and MD5 bindings.

  Ophal hashes passwords by iterating a digest `settings.user.password_hash.
  iterations` times, defaulting to 10,000. It used to resolve that digest
  through a chain of optional rocks -- `md5`, `sha1`, `lsha2`, `sha2` -- and,
  when none of them was installed, fall through to a pure-Lua SHA-256 that
  shipped with Ophal. Nothing in `INSTALL.md` asks for any of those rocks, so
  the fall-through was the live path on every documented install, and
  `README.md` presented it as a feature: "no cryptography library is needed".

  It was never needed. OpenResty ships `resty.md5`, `resty.sha1` and
  `resty.sha224` through `resty.sha512`, and nothing ever asked. Measured by
  `tests/bench/digest_bench.lua` on 2026-09-10: a 10,000-iteration
  `password_digest` cost **676 ms** of pure-Lua CPU against **5.2 ms** here,
  which is 129x -- and those 676 ms were spent inside a request, with the whole
  worker blocked, on an endpoint any visitor can reach with a username they
  guessed.

  The digests are byte-identical, which is the property that made the swap
  available at all: `password_verify()` re-derives the entire stored string and
  `secure_equals` it, so an implementation differing by one nibble would lock
  out every account on the site rather than fail visibly. The bench asserts
  agreement over the iteration chain, not over a single call, because each
  round feeds the previous round's hex back in.

  There is deliberately **no fallback**. A missing binding here means the
  process is not OpenResty, which is not a condition Ophal can hash its way
  out of -- the same call this project already makes in `includes/json.lua`,
  `driver/lsqlite3.lua` and `driver/resty_mysql.lua`.
]]

local type, require, pcall = type, require, pcall

--[[ Constructors, not functions: each is `new()` / `update()` / `final()`.

  The names are the ones `settings.user.password_hash.algorithm` accepts, which
  are also the names the old rock chain accepted, so a site that had configured
  one keeps working.
]]
local MODULE_NAMES = {
  md5 = 'resty.md5',
  sha1 = 'resty.sha1',
  sha224 = 'resty.sha224',
  sha256 = 'resty.sha256',
  sha384 = 'resty.sha384',
  sha512 = 'resty.sha512',
}

local ALGORITHMS = 'md5, sha1, sha224, sha256, sha384, sha512'

--[[ `resty.string` is where `to_hex` lives, and it is resolved here rather than
  per call so a process without it says so at load.

  Lowercase hex is not incidental: `password_hash()` stores the digest into a
  string that `password_hash_parse()` reads back with `[0-9a-fA-F]+` and then
  lowercases, but `versioned_hash_format` in `tests/unit/test_password_hashing.
  lua` pins lowercase on the way out, and every hash already stored is
  lowercase. `to_hex_is_lowercase` in the bench is what holds it.
]]
local resolved, resty_string = pcall(require, 'resty.string')

if not resolved or type(resty_string) ~= 'table'
  or type(resty_string.to_hex) ~= 'function'
then
  error('resty.string is not available. It ships with OpenResty, so this\n'
    .. 'process is probably not OpenResty -- Ophal runs its command line under\n'
    .. 'resty too:\n'
    .. '  resty -c 512 ./ophal sha256 mypassword\n'
    .. 'More: https://github.com/ophal/core', 0)
end

local to_hex = resty_string.to_hex

--[[ Resolved once per algorithm and kept, because `password_digest()` asks for
  the same one ten thousand times in a row.
]]
local implementations = {}

local function implementation(algorithm)
  local cached = implementations[algorithm]

  if cached ~= nil then
    return cached
  end

  local module_name = MODULE_NAMES[algorithm]

  if module_name == nil then
    error(("digest: unknown algorithm '%s'; Ophal supports %s")
      :format(tostring(algorithm), ALGORITHMS), 0)
  end

  local found, module_impl = pcall(require, module_name)

  if not found or type(module_impl) ~= 'table'
    or type(module_impl.new) ~= 'function'
  then
    error(("digest: '%s' needs %s, which ships with OpenResty -- so this\n")
      :format(algorithm, module_name)
      .. 'process is probably not OpenResty.\n'
      .. 'More: https://github.com/ophal/core', 0)
  end

  implementations[algorithm] = module_impl

  return module_impl
end

local M = {}

--[[ `data` hashed with `algorithm`, as lowercase hex.

  A fresh state per call rather than one reset between calls. `reset()` would
  save an allocation, but a state kept across calls is worker-lifetime mutable
  state shared by every request in flight -- and a request that yields between
  `update()` and `final()` would hand its half-built digest to whoever ran next.
  Nothing here yields today; that is not a reason to build something that
  breaks when something does. It is the same argument
  `includes/request_state.lua` records for `_SESSION` and `_GET`.
]]
function M.hex(algorithm, data)
  local state = implementation(algorithm):new()

  if state == nil then
    error(("digest: could not start a %s digest"):format(algorithm), 0)
  end

  if not state:update(data or '') then
    error(("digest: could not hash with %s"):format(algorithm), 0)
  end

  return to_hex(state:final())
end

--[[ Whether an algorithm name is one Ophal can hash with, without hashing.

  `includes/install.lua` wants to refuse a misconfigured `algorithm` where it is
  typed rather than at the site's first sign-in.
]]
function M.supports(algorithm)
  return MODULE_NAMES[algorithm] ~= nil
end

return M
