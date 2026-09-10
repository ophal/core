--[[ The JSON shim's contract, on both of its branches.

  `includes/json.lua` spans two backends that disagree in four ways, and the
  point of it is that a caller cannot tell which one it got. So almost every
  assertion here runs **twice** -- once against the backend this runtime
  actually has, and once against the other branch -- and asserts the same
  answer both times.

  The unit suite runs under `lua5.1`, which has no `cjson`, so the cjson branch
  is driven with a stand-in carrying the shapes the real library has: a
  lightuserdata-like null sentinel, `empty_array_mt`, and a `decode` answering
  two values. That is a model, and this project distrusts models -- so the real
  library's real behaviour is pinned separately, against the real thing, in
  `tests/bench/json_bench.lua`. What is tested here is the shim's own branching:
  that the null strip runs, that the array tag is the live backend's, and that
  the error contract holds on the side the bench cannot reach.
]]

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

local function assert_true(label, got)
  assert_eq(label, not not got, true)
end

local function assert_match(label, got, pattern)
  if tostring(got):match(pattern) then
    pass_count = pass_count + 1
    io.write(('  ok %s\n'):format(label))
  else
    fail_count = fail_count + 1
    io.write(('  FAIL %s: %q did not match %q\n'):format(
      label, tostring(got), pattern))
  end
end

--[[ A stand-in for `cjson.safe`, at the shapes the real one has.

  `null` is a table here rather than a lightuserdata, because Lua cannot make
  one -- what matters for the shim is that it is a value the decoder returns
  and that it is neither nil nor false, which a table is. Its encoder answers
  `nil, err` rather than raising, which is the half of the contract the shim
  does not have to repair on this side.
]]
local function cjson_stub()
  local NULL = setmetatable({}, {__tostring = function() return 'null' end})
  local ARRAY_MT = {}

  return {
    null = NULL,
    empty_array_mt = ARRAY_MT,

    decode = function(input)
      if input == '{bad' then
        return nil, 'Expected object key string but found invalid token'
      end
      if input == '5' then return 5 end
      if input == '{"a":null}' then return {a = NULL} end
      if input == '{"a":{"b":null}}' then return {a = {b = NULL}} end
      if input == '{"list":[1,null,3]}' then return {list = {1, NULL, 3}} end

      return {a = 1}
    end,

    encode = function(value)
      if type(value) ~= 'table' then return nil, 'not a table' end
      if getmetatable(value) == ARRAY_MT and next(value) == nil then
        return '[]'
      end
      if next(value) == nil then return '{}' end
      if value.cycle then return nil, 'Cannot serialise, excessive nesting' end
      if value.n ~= nil then
        return nil, 'Cannot serialise number: must not be NaN or Infinity'
      end

      return '{"encoded":true}'
    end,
  }
end

-- Load the shim fresh against a chosen backend.
local function load_shim(with_cjson)
  package.loaded['includes.json'] = nil
  package.loaded['cjson.safe'] = with_cjson and cjson_stub() or nil

  -- `require` caches a failed load as nothing, so the dkjson branch is reached
  -- simply by there being no `cjson.safe` entry and none on disk.
  local shim = require 'includes.json'

  package.loaded['cjson.safe'] = nil
  package.loaded['includes.json'] = nil

  return shim
end

local cjson_shim = load_shim(true)
local dkjson_shim = load_shim(false)

local backends = {
  {name = 'cjson', json = cjson_shim},
  {name = 'dkjson', json = dkjson_shim},
}

io.write('test_json\n')

-- Each backend reports itself, which is what the smoke suite asserts against so
-- a `lua_package_cpath` edit cannot silently demote a worker to the fallback.
assert_eq('the cjson branch names itself', cjson_shim.backend(), 'cjson')
assert_eq('the dkjson branch names itself', dkjson_shim.backend(), 'dkjson')

for _, backend in ipairs(backends) do
  local json, at = backend.json, backend.name

  -- -- the decode contract, identical on both -------------------------------

  --[[ A nil input is the live defect this shim closes: `request_get_body()`
    answers nil for a method with no body, dkjson raises on it, and the pcall
    above turned that raise into a 200 whose body carried a dkjson source path.
  ]]
  local value, err = json.decode(nil)
  assert_eq(at .. ': a nil input decodes to nil', value, nil)
  assert_eq(at .. ': a nil input is refused by name', err, 'no JSON input')

  value, err = json.decode('')
  assert_eq(at .. ': an empty input is refused', value, nil)
  assert_eq(at .. ': an empty input is refused by name', err, 'no JSON input')

  value, err = json.decode(42)
  assert_eq(at .. ': a non-string input is refused', value, nil)
  assert_eq(at .. ': a non-string input is refused by name', err, 'no JSON input')

  --[[ Valid JSON that is not an object. Every consumer indexes what it gets --
    four request bodies and a job payload -- so a number reaching one of them
    raises rather than answering wrongly.
  ]]
  value, err = json.decode('5')
  assert_eq(at .. ': a bare scalar is refused', value, nil)
  assert_eq(at .. ': a bare scalar is refused by name', err, 'expected a JSON object')

  value, err = json.decode('{bad')
  assert_eq(at .. ': malformed JSON decodes to nil', value, nil)
  assert_true(at .. ': malformed JSON reports why', type(err) == 'string' and #err > 0)

  --[[ Never three returns, on either backend.

    dkjson's own `decode` answers `value, position, message`, and the five call
    sites this shim replaces all read it into three names and guarded on the
    third. cjson answers two, so under a bare swap the message would land in
    `pos` and `err` would stay nil -- the guard stops firing, on four parsers
    whose input is a request body. Two is the contract, and an error is always
    in the second slot.
  ]]
  assert_true(at .. ': decode never answers a third value',
    select('#', json.decode('{"a":1}')) <= 2)
  assert_eq(at .. ': decode answers exactly two values on failure',
    select('#', json.decode('{bad')), 2)

  local _, second = json.decode('{"a":1}')
  assert_eq(at .. ': the error slot is nil on success', second, nil)

  assert_eq(at .. ': a valid object decodes', type(json.decode('{"a":1}')), 'table')

  -- -- null, which is the difference with teeth -----------------------------

  --[[ cjson's sentinel is truthy, so it passes every presence check in this
    codebase and would reach `password_verify`, `secure_equals` and a bound SQL
    parameter. Stripped, both backends answer "absent".
  ]]
  assert_eq(at .. ': a null value reads as absent', json.decode('{"a":null}').a, nil)
  assert_eq(at .. ': a nested null reads as absent',
    json.decode('{"a":{"b":null}}').a.b, nil)
  assert_eq(at .. ': a null inside a list reads as absent',
    json.decode('{"list":[1,null,3]}').list[2], nil)

  -- -- the encode contract --------------------------------------------------

  --[[ Empty collections state their own shape. dkjson writes `[]` for a bare
    `{}` and cjson writes `{}`, and there is no flag that reconciles them, so a
    site that means one or the other has to say so.
  ]]
  assert_eq(at .. ': an empty array encodes as []', json.encode(json.array()), '[]')
  assert_eq(at .. ': an empty object encodes as {}', json.encode(json.object()), '{}')

  -- The tag goes inert once there is content, so a collection can be tagged
  -- where it is built rather than where it turns out to be empty.
  assert_true(at .. ': a populated array is not empty',
    json.encode(json.array({1, 2})) ~= '[]')

  -- An existing table can be tagged in place, which is the shape the call sites
  -- need: a list comes back from a loader and is assigned into the response.
  local rows = {}
  assert_eq(at .. ': an existing table can be tagged as an array',
    json.encode(json.array(rows)), '[]')

  -- -- nothing raises -------------------------------------------------------

  --[[ dkjson raises from `encode` on a cycle, an unsupported type and infinity.
    A raise here reaches the same `pcall` that produced the 200-with-a-path, so
    the shim owes its callers an error value rather than an exception.
  ]]
  local cyclic = {cycle = true}
  cyclic.self = cyclic

  local encoded, encode_err = json.encode(cyclic)
  assert_eq(at .. ': a cycle encodes to nil rather than raising', encoded, nil)
  assert_true(at .. ': a cycle reports why', type(encode_err) == 'string')

  assert_true(at .. ': a cycle error carries no source path',
    not tostring(encode_err):match('%.lua:%d'))

  --[[ Infinity is the case that proves the source prefix is actually stripped.

    dkjson raises `error(msg)` for a cycle, which carries no position, but its
    number path overflows an internal buffer and raises from inside the library
    -- so that message arrives as `.../dkjson.lua:312: table overflow`, with an
    absolute path in it. The message is put into a response body by
    `theme.json`, which is how a service error came to disclose the filesystem
    layout in the first place, so the prefix comes off before it is returned.
  ]]
  local infinite, infinite_err = json.encode({n = 1/0})
  assert_eq(at .. ': infinity encodes to nil rather than raising', infinite, nil)
  assert_true(at .. ': an encode error carries no source path',
    not tostring(infinite_err):match('%.lua:%d'))
  assert_true(at .. ': the useful half of the message survives',
    #tostring(infinite_err) > 0)
end

-- -- the two branches disagree only where they are supposed to ---------------

--[[ The array tag is the live backend's own, and that is not a detail: cjson
  ignores dkjson's `__jsontype` and answers `{}` for a table tagged as an array,
  so a shim picking one metatable for both would be right on the backend it was
  written against and silently wrong on the other.
]]
assert_true('each branch uses its own array tag',
  getmetatable(cjson_shim.array()) ~= getmetatable(dkjson_shim.array()))

-- The dkjson branch reaches the real library, so its parse error is the real
-- one rather than the stub's.
local _, real_err = dkjson_shim.decode('{bad')
assert_match('the dkjson branch reports a real parse error', real_err, 'no valid JSON value')

io.write(('\n%d passed, %d failed\n'):format(pass_count, fail_count))
os.exit(fail_count == 0 and 0 or 1)
