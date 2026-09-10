--[[ The JSON shim's contract, against the real library.

  `includes/json.lua` is cjson with four of its behaviours pinned down, so
  everything here runs against the actual `cjson.safe` the worker uses rather
  than a stand-in. That is the point of the suite having moved onto LuaJIT: the
  library under test is the one production loads.

  The backend-specific measurements -- how much faster it is, and what dkjson
  did differently before the swap -- are in `tests/bench/json_bench.lua`.
]]

local json = require 'includes.json'

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

io.write('test_json\n')

assert_eq('the backend is cjson', json.backend(), 'cjson')

io.write '\n-- decode refuses what no caller here can use --\n'

--[[ A nil input is the live defect this shim closes. `request_get_body()`
  answers nil for a method with no body, and `GET /comment/save` used to carry
  that nil into the parser -- dkjson raised on it, the dispatcher's pcall turned
  the raise into a string, and `theme.json` rendered the string, source path and
  all, at HTTP 200. The guard is here rather than at the call sites because
  there are four of them and a fifth would spell it a fifth way.
]]
local value, err = json.decode(nil)
assert_eq('a nil input decodes to nil', value, nil)
assert_eq('a nil input is refused by name', err, 'no JSON input')

value, err = json.decode('')
assert_eq('an empty input is refused', value, nil)
assert_eq('an empty input is refused by name', err, 'no JSON input')

value, err = json.decode(42)
assert_eq('a non-string input is refused', value, nil)
assert_eq('a non-string input is refused by name', err, 'no JSON input')

--[[ Valid JSON that is not an object. Every consumer indexes what it gets --
  four request bodies and a job payload -- so a number reaching one of them
  raises rather than answering wrongly.
]]
value, err = json.decode('5')
assert_eq('a bare scalar is refused', value, nil)
assert_eq('a bare scalar is refused by name', err, 'expected a JSON object')

value, err = json.decode('"a string"')
assert_eq('a bare string is refused', value, nil)

value, err = json.decode('{bad')
assert_eq('malformed JSON decodes to nil', value, nil)
assert_true('malformed JSON reports why', type(err) == 'string' and #err > 0)

io.write '\n-- and answers two values, never three --\n'

--[[ dkjson answered `value, position, message` and every call site read it into
  three names, guarding on the third. cjson answers two. Had the swap been made
  without this contract, the message would have landed in `pos` and `err` would
  have stayed nil -- the guard stops firing, on four parsers whose input is a
  request body, with nothing raised and nothing logged.
]]
assert_true('decode never answers a third value',
  select('#', json.decode('{"a":1}')) <= 2)
assert_eq('decode answers exactly two values on failure',
  select('#', json.decode('{bad')), 2)

local _, second = json.decode('{"a":1}')
assert_eq('the error slot is nil on success', second, nil)

assert_eq('a valid object decodes', type(json.decode('{"a":1}')), 'table')

io.write '\n-- null, which is the difference with teeth --\n'

--[[ cjson's sentinel is a lightuserdata: neither nil nor false, so truthy, so
  `seawolf.variable.empty` reports it non-empty. Stripped, a null reads as an
  absent key -- which is what every call site in this codebase already assumes.
]]
assert_eq('a null value reads as absent', json.decode('{"a":null}').a, nil)
assert_eq('a nested null reads as absent',
  json.decode('{"a":{"b":null}}').a.b, nil)
assert_eq('a null inside a list reads as absent',
  json.decode('{"list":[1,null,3]}').list[2], nil)

-- The shape of the failure this prevents, stated directly: unstripped, the
-- sentinel passes a presence check that a missing key would fail.
local raw = require('cjson.safe').decode('{"pass":null}')
assert_true('the raw sentinel is truthy', raw.pass and true or false)
assert_eq('and the shim does not pass it on', json.decode('{"pass":null}').pass, nil)

io.write '\n-- empty collections state their own shape --\n'

assert_eq('an empty array encodes as []', json.encode(json.array()), '[]')
assert_eq('an empty object encodes as {}', json.encode(json.object()), '{}')

-- The tag goes inert once there is content, so a collection can be tagged where
-- it is built rather than where it turns out to be empty.
assert_eq('a populated array still encodes as one',
  json.encode(json.array({1, 2})), '[1,2]')

-- An existing table can be tagged in place, which is the shape the call sites
-- need: a list comes back from a loader and is assigned into the response.
local rows = {}
assert_eq('an existing table can be tagged as an array',
  json.encode(json.array(rows)), '[]')

-- `object()` must not clear a metatable the caller's table already had; it
-- states intent, and for cjson an empty table is already an object.
local tagged = setmetatable({}, {marker = true})
assert_true('object() leaves an existing metatable alone',
  getmetatable(json.object(tagged)) ~= nil)

io.write '\n-- nothing raises --\n'

--[[ A raise inside a page callback is caught by `route_execute_callback`'s
  pcall, which turns it into a string -- and a Lua error string begins with the
  file and line it was raised at, which `theme.json` renders into the response.
  So the encoder owing its caller a value rather than an exception is a
  disclosure property, not a style one.
]]
local cyclic = {}
cyclic.self = cyclic

local encoded, encode_err = json.encode(cyclic)
assert_eq('a cycle encodes to nil rather than raising', encoded, nil)
assert_true('a cycle reports why', type(encode_err) == 'string')

encoded, encode_err = json.encode({n = 1/0})
assert_eq('infinity encodes to nil rather than raising', encoded, nil)
assert_true('infinity reports why', type(encode_err) == 'string')

encoded, encode_err = json.encode({f = print})
assert_eq('an unsupported type encodes to nil rather than raising', encoded, nil)

-- And no error string the shim returns names a source file, because they are
-- rendered into response bodies.
for _, message in ipairs{
  select(2, json.decode('{bad')),
  select(2, json.encode(cyclic)),
  select(2, json.encode({n = 1/0})),
} do
  assert_true('an error message carries no source path',
    not tostring(message):match('%.lua:%d'))
end

io.write(('\n%d passed, %d failed\n'):format(pass_count, fail_count))
os.exit(fail_count == 0 and 0 or 1)
