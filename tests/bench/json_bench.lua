--[[ What a JSON backend costs, and where the two disagree.

Ophal ran every service response, every job payload and -- once the session
  store lands -- every session file through `dkjson`, which is pure Lua, while
  OpenResty's C `cjson` sat unused in the same process. Swapping them was
  obvious enough that it deserved the same gate stages 8.3 and 8.4 got: a
  number, before anything moved. This file is that number, and it is kept
  because the reasoning behind `includes/json.lua` is only checkable with both
  libraries side by side -- `dkjson` is vendored for this and nothing else.

  Two questions, and the second one is the reason this file is longer than a
  timing harness needs to be.

  **What does it cost?** The session store is the case that decides it, because
  it is the one where JSON *replaces* something rather than being chosen over an
  alternative spelling of itself: today a session file is `table_dump` output
  read back with `loadstring`, so the store's baseline is Lua's own serializer
  rather than another JSON library. A session is 27 to 95 bytes and the write
  costs two syscalls, so the format is expected to be noise against the I/O --
  which is the point, because it means the safety is free. Expected is not
  measured.

  **Where do they disagree?** Every difference below is a silent output change
  under a naive swap: nothing raises, nothing is slower, and the bytes on the
  wire are not the same bytes. Those are asserted rather than timed, and they
  fail this harness when a backend upgrade moves one -- `run_json_bench.sh`
  exits non-zero on any of them, for the reason `run_injection_probe.sh`
  already records: a harness that always exits 0 is a test that cannot fail the
  build.

  Run: bash tests/bench/run_json_bench.sh
]]

package.path = './?.lua;./?/init.lua;' .. package.path

local ITERATIONS = tonumber(os.getenv('OPHAL_BENCH_ITERATIONS') or '') or 100000

local contrib = require 'seawolf.contrib'
local table_dump = contrib.table_dump

local dkjson = require 'dkjson'
local cjson = require 'cjson.safe'

local format, concat, rep = string.format, table.concat, string.rep
local setmeta, getmeta = setmetatable, getmetatable

-- --------------------------------------------------------------- report ----

--[[ Somewhere for results to go.

  Same reason `layer_bench.lua` has one: LuaJIT deletes a loop whose result is
  never used, and it proved a string result always truthy in an earlier bench
  here, reporting `string.format` at 3 ns. Every measured value is accumulated.
]]
local sink = 0

local function consume(value)
  local kind = type(value)

  if kind == 'string' then
    sink = sink + #value
  elseif kind == 'table' then
    sink = sink + 1
  elseif value ~= nil then
    sink = sink + 1
  end
end

local report = {}

local function record(group, label, ops, seconds, note)
  report[#report + 1] = {
    group = group,
    label = label,
    ops = ops,
    seconds = seconds,
    rate = seconds > 0 and ops / seconds or 0,
    ns = seconds > 0 and (seconds * 1e9) / ops or 0,
    note = note,
  }
end

--[[ CPU time at microsecond resolution.

  Nothing here touches a socket, so `os.clock()` is the right instrument and
  `ngx.now()`'s millisecond wall clock is the wrong one.
]]
local function timed(group, label, iterations, fn, note)
  -- One pass before the clock starts, so a first-call compile or an allocation
  -- the backend makes once is not charged to the measurement.
  consume(fn(1))

  local started = os.clock()

  for i = 1, iterations do
    consume(fn(i))
  end

  record(group, label, iterations, os.clock() - started, note)
end

-- ----------------------------------------------------------- assertions ----

local passed, failed = 0, 0

local function ok(name, condition, detail)
  if condition then
    passed = passed + 1
    print(format('ok   %s', name))
  else
    failed = failed + 1
    print(format('FAIL %s%s', name, detail and (' -- ' .. detail) or ''))
  end
end

local function equals(name, got, want)
  ok(name, got == want, format('got %s, want %s', tostring(got), tostring(want)))
end

-- ------------------------------------------------------------- fixtures ----

local HEX = 'a3f1c0d94b27e6580f1a2b3c4d5e6f708192a3b4c5d6e7f80112233445566778'

-- What a signed-in session actually holds. `user_id` arrives from the account
-- and `csrf_token` from `includes/security.lua`; nothing else in the codebase
-- writes to `_SESSION` today.
local SESSION = {user_id = 2, csrf_token = HEX}

-- And the cheapest one that exists at all: a visitor who asked for a token
-- before signing in.
local SESSION_SMALL = {csrf_token = HEX}

--[[ A service response, at the shape `comment/fetch` returns.

  It is the JSON response in this codebase that carries the most bytes -- each
  row is rendered to HTML server-side and the markup ships inside the payload --
  so it is the encode that would show a difference if any does.
]]
local function service_response(rows)
  local list = {}

  for i = 1, rows do
    list[i] = {
      id = i,
      entity_id = 1,
      parent_id = 0,
      subject = 'Re: a title of about the length titles have',
      name = 'commenter ' .. i,
      created = 1757462400 + i,
      rendered = format(
        '<article class="comment" id="comment-%d"><h3><a href="/comment/%d">%s</a></h3>' ..
        '<div class="body"><p>%s</p></div></article>',
        i, i, 'Re: a title', rep('a sentence of comment body text. ', 4)),
    }
  end

  return {success = true, list = list}
end

local SERVICE = service_response(8)

-- The request body the four service decoders parse. `csrf_token` is always
-- present, because `csrf_validate_request()` reads it out of the parsed body.
local BODY = cjson.encode{
  csrf_token = HEX,
  subject = 'Re: a title of about the length titles have',
  body = rep('a sentence of comment body text. ', 6),
  entity_id = 1,
}

-- ------------------------------------------ the session's current format ----

--[[ Exactly what `session_write_close()` does today, at
  `includes/session.lua:322` -- the `'return '` prefix, the accumulating table,
  the `tconcat`. Timing `table_dump` alone would flatter it by the concat.
]]
local function dump_encode(value)
  local raw = {'return '}
  local dumped, err = pcall(table_dump, value, function (s)
    raw[#raw + 1] = s
  end)

  if not dumped then return nil, err end

  return concat(raw)
end

--[[ And what `session_start()` does at `includes/session.lua:281`: `loadstring`,
  an empty environment, and a `pcall` of the result.

  The bytecode guard above it is part of the cost of this format existing, so it
  is measured with it. A JSON parser needs no such check, which is most of the
  argument for the change.
]]
local function dump_decode(text)
  if text:byte(1) == 27 then return nil, 'binary bytecode in session data' end

  local fn, err = loadstring(text)

  if not fn then return nil, err end

  setfenv(fn, {})

  local parsed, value = pcall(fn)

  if not parsed then return nil, value end

  return type(value) == 'table' and value or {}
end

-- ------------------------------------------------- the candidate null strip ----

--[[ cjson decodes JSON `null` to a lightuserdata sentinel, and dkjson -- as
  this codebase calls it, with `nullval = nil` -- drops the key.

  Lua counts everything but `nil` and `false` as true, so the sentinel is
  truthy, and `seawolf.variable.empty` reports it non-empty. A body sending
  `{"password": null}` would therefore satisfy every "did they send one?" check
  in the codebase and arrive at `password_verify`, at `secure_equals`, and at a
  bound SQL parameter as an opaque userdata nothing downstream expects.

  This is the pass the shim will carry. It is timed because stripping is per
  key rather than per document, so it is a cost that scales with the payload
  and it should be paid with the number in view.
]]
local NULL = cjson.null

local function strip_nulls(value)
  if type(value) ~= 'table' then
    return value ~= NULL and value or nil
  end

  for k, v in pairs(value) do
    if v == NULL then
      value[k] = nil
    elseif type(v) == 'table' then
      strip_nulls(v)
    end
  end

  return value
end

-- ------------------------------------------------------------ the timing ----

local SERVICE_ITERATIONS = math.max(1, math.floor(ITERATIONS / 20))

local session_dump = dump_encode(SESSION)
local session_cjson = cjson.encode(SESSION)
local session_dkjson = dkjson.encode(SESSION)

timed('encode: session (signed in)', 'table_dump + concat', ITERATIONS, function()
  return dump_encode(SESSION)
end, format('%d bytes', #session_dump))

timed('encode: session (signed in)', 'cjson', ITERATIONS, function()
  return cjson.encode(SESSION)
end, format('%d bytes', #session_cjson))

timed('encode: session (signed in)', 'dkjson', ITERATIONS, function()
  return dkjson.encode(SESSION)
end, format('%d bytes', #session_dkjson))

timed('encode: session (token only)', 'table_dump + concat', ITERATIONS, function()
  return dump_encode(SESSION_SMALL)
end)

timed('encode: session (token only)', 'cjson', ITERATIONS, function()
  return cjson.encode(SESSION_SMALL)
end)

timed('encode: session (token only)', 'dkjson', ITERATIONS, function()
  return dkjson.encode(SESSION_SMALL)
end)

timed('decode: session', 'loadstring + setfenv', ITERATIONS, function()
  return dump_decode(session_dump)
end)

timed('decode: session', 'cjson', ITERATIONS, function()
  return cjson.decode(session_cjson)
end)

timed('decode: session', 'dkjson', ITERATIONS, function()
  return dkjson.decode(session_dkjson, 1, nil)
end)

--[[ The round trip is the number the store is actually judged on: a resumed
  session decodes on the way in and encodes on the way out, once each. ]]
timed('round trip: session', 'table_dump + loadstring', ITERATIONS, function()
  return dump_decode(dump_encode(SESSION))
end)

timed('round trip: session', 'cjson', ITERATIONS, function()
  return cjson.decode(cjson.encode(SESSION))
end)

timed('round trip: session', 'dkjson', ITERATIONS, function()
  return dkjson.decode(dkjson.encode(SESSION), 1, nil)
end)

--[[ Three row counts, because a ratio that holds across them says the
  difference is per byte rather than a fixed cost being amortised -- and because
  a comment thread is not a fixed size. It does hold: about 4 ns a byte through
  cjson against about 40 through dkjson, so a 32-comment thread spends half a
  millisecond of CPU in the encoder alone on a request whose SQL budget is two
  queries.
]]
for _, rows in ipairs{1, 8, 32} do
  local payload = rows == 8 and SERVICE or service_response(rows)
  local group = format('encode: service response (%d rows)', rows)

  timed(group, 'cjson', SERVICE_ITERATIONS, function()
    return cjson.encode(payload)
  end, format('%d bytes', #cjson.encode(payload)))

  timed(group, 'dkjson', SERVICE_ITERATIONS, function()
    return dkjson.encode(payload)
  end, format('%d bytes', #dkjson.encode(payload)))
end

timed('decode: request body', 'cjson', ITERATIONS, function()
  return cjson.decode(BODY)
end, format('%d bytes', #BODY))

timed('decode: request body', 'cjson + null strip', ITERATIONS, function()
  return strip_nulls(cjson.decode(BODY))
end)

timed('decode: request body', 'dkjson', ITERATIONS, function()
  return dkjson.decode(BODY, 1, nil)
end)

-- ------------------------------------------------------- the disagreements ----

print('')
print('-- where the two backends disagree ------------------------------------')
print('')

--[[ 1. The empty table.

  Lua has one table type, so `{}` is both an empty list and an empty object and
  every encoder has to guess. They guess differently, and the direction matters:
  a browser doing `for (const c of response.list)` works on `[]` and throws on
  `{}`, so this breaks a page with no comments while leaving a page with three
  comments working.

  There is no flag that makes cjson match, because the flag it has --
  `encode_empty_table_as_object` -- is already at the value that produces this.
  So each site states its own shape instead, through the shim's helpers below.
]]
equals('dkjson encodes an empty table as an array', dkjson.encode{}, '[]')
equals('cjson encodes an empty table as an object', cjson.encode{}, '{}')

--[[ 2. The shape helpers, per backend.

  The metatables are **not** interchangeable, which is the reason this belongs
  in a shim rather than in a shared constant: cjson ignores dkjson's
  `__jsontype` tag and answers `{}` for a table tagged as an array. A shim that
  picked one metatable for both backends would be correct on whichever one it
  was written against and silently wrong on the other.
]]
local dk_array, dk_object = setmeta({}, {__jsontype = 'array'}), setmeta({}, {__jsontype = 'object'})
local cj_array = setmeta({}, cjson.empty_array_mt)

equals('dkjson honours an array tag', dkjson.encode(dk_array), '[]')
equals('dkjson honours an object tag', dkjson.encode(dk_object), '{}')
equals('cjson honours empty_array_mt', cjson.encode(cj_array), '[]')
ok('cjson ignores a dkjson array tag', cjson.encode(dk_array) == '{}',
  'a shared metatable would be wrong on one backend')

-- And each goes inert once the table has content, which is what makes it safe
-- to tag a collection that is usually non-empty.
equals('an array tag is inert when populated (dkjson)',
  dkjson.encode(setmeta({1, 2}, {__jsontype = 'array'})), '[1,2]')
equals('an array tag is inert when populated (cjson)',
  cjson.encode(setmeta({1, 2}, cjson.empty_array_mt)), '[1,2]')

--[[ 3. The null sentinel.

  Not merely a different spelling: it is truthy, so it passes a presence check
  that a missing key would fail.
]]
local decoded_null = cjson.decode('{"a":null}')
local dk_null = dkjson.decode('{"a":null}', 1, nil)

equals('cjson decodes null to a sentinel', type(decoded_null.a), 'userdata')
ok('the cjson null sentinel is truthy', decoded_null.a and true or false,
  'a presence check would pass on it')
equals('dkjson drops a null key', dk_null.a, nil)
equals('the strip pass restores dkjson behaviour',
  strip_nulls(cjson.decode('{"a":null}')).a, nil)

--[[ 4. The decode signature, which is the sharpest edge in the migration.

  dkjson answers `value, position, message` and cjson answers `value, message`.
  Every one of the five call sites is written `parsed, pos, err = decode(...)`
  and guards on `if err then`. Read cjson's two returns into those three names
  and the message lands in `pos` while `err` stays nil -- so the guard stops
  firing, on four parsers whose input is a request body. Nothing raises and
  nothing logs; a malformed POST is simply treated as valid.
]]
local dk_value, dk_pos, dk_err = dkjson.decode('{bad', 1, nil)
local cj_value, cj_err, cj_third = cjson.decode('{bad')

equals('dkjson reports a parse error in the third return', type(dk_err), 'string')
equals('dkjson reports a position in the second', type(dk_pos), 'number')
equals('cjson reports a parse error in the second return', type(cj_err), 'string')
equals('cjson has no third return', cj_third, nil)
ok('read into three names, cjson leaves the error slot nil',
  select('#', cjson.decode('{bad')) == 2,
  'this is what silences `if err then` at five call sites')

--[[ 5. A nil input, which is the live defect this work closes.

  `request_get_body()` answers nil for a method with no body, and today that nil
  reaches dkjson, which *raises* -- the pcall above it turns the raise into an
  error string carrying absolute filesystem paths, and `theme.json` renders it
  at HTTP 200. cjson.safe declines instead of raising, so the swap alone would
  hide the symptom on one backend and leave it on the other. The shim refuses a
  non-string before either backend sees it, so the answer is the same in both
  runtimes.
]]
ok('dkjson raises on a nil input', not pcall(dkjson.decode, nil, 1, nil),
  'this is what leaks a stack trace at 200 today')
ok('cjson.safe declines a nil input rather than raising',
  select(1, pcall(cjson.decode, nil)) == true,
  'so a bare swap would fix it on one runtime only')

--[[ 6. Forward slashes, which is a live output difference on every response.

  cjson escapes `/` as `\/` by default and dkjson does not. Both are valid JSON
  and decode identically, so nothing breaks -- but the bytes change, and an
  ETag is computed over bytes.

  The shim must **not** turn it off. `encode_escape_forward_slash` is shared
  between `cjson` and `cjson.safe` -- unlike `encode_empty_table_as_object`,
  which is not -- so it is VM-global state, and changing it would reach every
  other cjson user in the worker.
]]
equals('cjson escapes a forward slash', cjson.encode{a = 'x/y'}, '{"a":"x\\/y"}')
equals('dkjson does not', dkjson.encode{a = 'x/y'}, '{"a":"x/y"}')
ok('escape_forward_slash is shared between cjson and cjson.safe',
  (function()
    local strict = require 'cjson'
    strict.encode_escape_forward_slash(false)
    local shared = cjson.encode{a = 'x/y'} == '{"a":"x/y"}'
    strict.encode_escape_forward_slash(true)
    return shared
  end)(),
  'so the shim must leave it alone')
ok('encode_empty_table_as_object is not shared',
  (function()
    local strict = require 'cjson'
    strict.encode_empty_table_as_object(false)
    local isolated = cjson.encode{} == '{}'
    strict.encode_empty_table_as_object(true)
    return isolated
  end)(),
  'configure the exact module you encode with')

-- ------------------------------------------------------------- the report ----

print('')
print('-- timings -----------------------------------------------------------')
print('')
print(format('%-34s %-24s %12s %10s  %s', 'group', 'candidate', 'ops/sec', 'ns/op', 'note'))

local group

for _, row in ipairs(report) do
  if row.group ~= group then
    group = row.group
    print(format('%s', group))
  end

  print(format('%-34s %-24s %12d %10.0f  %s', '', row.label, row.rate, row.ns, row.note or ''))
end

print('')
print(format('%s, cjson %s, %d iterations',
  dkjson.version or 'dkjson (unversioned)', require('cjson')._VERSION, ITERATIONS))
print(format('%d passed, %d failed', passed, failed))

-- Keeps the accumulator reachable so LuaJIT cannot delete the work above it.
if sink < 0 then print(sink) end

os.exit(failed == 0 and 0 or 1)
