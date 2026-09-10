--[[ One JSON layer, over whichever backend the runtime actually has.

  OpenResty ships `cjson` -- C, and about nine times faster on a service
  response than the pure-Lua `dkjson` this codebase used everywhere -- but the
  `lua5.1` the command line names has no `cjson` at all. So neither library can
  simply replace the other, and every call site would otherwise have to know
  which one it got.

  The two disagree in four ways that a straight swap would have changed
  silently, which is most of the reason this file exists rather than a
  `require` at each call site. Every one of them is measured and pinned in
  `tests/bench/json_bench.lua`; the short version:

  - **An empty table.** dkjson writes `[]`, cjson writes `{}`. Lua has one table
    type, so both are guesses, and there is no flag that reconciles them --
    cjson's `encode_empty_table_as_object` is already at the value that produces
    this. `M.array()` and `M.object()` let a caller state its shape instead of
    inheriting a guess, and they apply the tag the **live** backend understands:
    the metatables are not interchangeable, and cjson answers `{}` for a table
    carrying dkjson's array tag.
  - **`null`.** cjson decodes it to a lightuserdata sentinel; dkjson, called
    with `nullval = nil` as this codebase always called it, drops the key. The
    sentinel is neither `nil` nor `false`, so it is *truthy*, and
    `seawolf.variable.empty` reports it non-empty -- a body sending
    `{"pass": null}` would satisfy every presence check in the codebase and
    arrive at `password_verify`, at `secure_equals`, and at a bound SQL
    parameter. `M.decode` strips them, so both backends answer "absent".
  - **The decode signature.** dkjson answers `value, position, message` and
    cjson answers `value, message`. Read cjson's two returns into the three
    names the old call sites used and the message lands in `pos` while `err`
    stays nil, so `if err then` stops firing. `M.decode` answers
    `value, err` -- two, on both backends, forever.
  - **A nil input.** `request_get_body()` answers nil for a method with no body.
    dkjson *raises* on it and `cjson.safe` declines, so a bare swap would have
    fixed one runtime and left the other. `M.decode` refuses a non-string before
    either backend sees it.

  **Nothing here raises.** dkjson raises from `encode` on a cycle, on an
  unsupported type and on infinity, and from `decode` on a nil input; `pcall`
  above a raise turns it into an error string carrying a source path, and this
  codebase renders a service error into the response body. That is exactly how
  `GET /comment/save` came to answer HTTP 200 with a dkjson path in it. So every
  function here answers `value, err` and every error string is safe to render:
  the source prefix Lua puts on a raise is removed before it is returned.

  One thing this file deliberately does **not** do: touch
  `encode_escape_forward_slash`. cjson escapes `/` as `\/` by default and dkjson
  does not -- both are valid JSON and decode identically -- but that setting is
  shared between `cjson` and `cjson.safe`, so it is VM-global state reaching
  every other cjson user in the worker. `encode_empty_table_as_object` is *not*
  shared, which is the trap in the other direction: configure the exact module
  you encode with.
]]

local pcall, type, pairs, tostring = pcall, type, pairs, tostring
local setmetatable, require = setmetatable, require

local M = {}

local decode_raw, encode_raw, strip, ARRAY_MT, OBJECT_MT, BACKEND

--[[ Lua puts `<source>:<line>: ` on the front of a raise, and the source is an
  absolute path. The message after it is the useful part and carries nothing
  about the filesystem -- "table overflow", "reference cycle" -- so the prefix
  is removed rather than the whole string being discarded.
]]
local function without_source(message)
  if type(message) ~= 'string' then
    return 'cannot encode as JSON'
  end

  return (message:gsub('^.-:%d+:%s*', ''))
end

local resolved, cjson = pcall(require, 'cjson.safe')

if resolved and type(cjson) == 'table' and type(cjson.decode) == 'function' then
  BACKEND = 'cjson'

  local NULL = cjson.null

  -- In place, and `pairs` allows clearing a field it has already visited.
  -- Decoded JSON cannot hold a cycle, and the backend's own depth limit bounds
  -- the recursion.
  local function strip_nulls(value)
    for k, v in pairs(value) do
      if v == NULL then
        value[k] = nil
      elseif type(v) == 'table' then
        strip_nulls(v)
      end
    end

    return value
  end

  strip = strip_nulls

  decode_raw = cjson.decode
  encode_raw = cjson.encode

  -- An empty table is already an object here, so `object()` needs no tag; an
  -- array needs cjson's own marker, which it compares by identity.
  ARRAY_MT, OBJECT_MT = cjson.empty_array_mt, nil
else
  local dkjson = require 'dkjson'

  BACKEND = 'dkjson'

  -- `nullval = nil` is the third argument, and it is what makes a JSON null
  -- read as an absent key. It is the call this codebase has always made; it is
  -- spelled once here so no call site can forget it.
  decode_raw = function(input)
    local value, _, err = dkjson.decode(input, 1, nil)

    return value, err
  end

  -- dkjson raises where cjson declines, so the contract is restored here.
  encode_raw = function(value)
    local ok, result = pcall(dkjson.encode, value)

    if not ok then
      return nil, without_source(result)
    end

    return result
  end

  -- Nothing to strip: `nullval = nil` already dropped it.
  strip = function(value) return value end

  ARRAY_MT = {__jsontype = 'array'}
  OBJECT_MT = {__jsontype = 'object'}
end

--[[ Parse JSON into a table.

  Answers `table` or `nil, err`, and never raises. A non-string input, an empty
  one, and a document that is valid JSON but not an object are all refused:
  every consumer in this codebase indexes what it gets back -- four request
  bodies and a job payload -- so a scalar reaching one of them is an
  "attempt to index a number" raise rather than a wrong answer. Something that
  genuinely wants a bare JSON value can have a `decode_value` beside this; the
  point is that it would have to say so.
]]
function M.decode(input)
  if type(input) ~= 'string' or input == '' then
    return nil, 'no JSON input'
  end

  local value, err = decode_raw(input)

  if err ~= nil then
    return nil, without_source(err)
  end

  if type(value) ~= 'table' then
    return nil, 'expected a JSON object'
  end

  return strip(value)
end

--[[ Serialize a value as JSON.

  Answers `string` or `nil, err`, and never raises.
]]
function M.encode(value)
  local encoded, err = encode_raw(value)

  if encoded == nil then
    return nil, without_source(err)
  end

  return encoded
end

--[[ Tag a table so an *empty* one encodes as `[]` rather than `{}`.

  Both tags go inert once the table has entries, so a collection that is usually
  populated can be tagged where it is created rather than where it is found to
  be empty.
]]
function M.array(value)
  return setmetatable(value or {}, ARRAY_MT)
end

--[[ And the other way: an empty table that must encode as `{}`.

  `OBJECT_MT` is nil on the cjson branch, because an empty table is already an
  object there. It is tested rather than passed straight to `setmetatable`,
  which would *remove* whatever metatable the caller's table already had -- the
  call sites tag tables they did not create.
]]
function M.object(value)
  value = value or {}

  if OBJECT_MT ~= nil then
    setmetatable(value, OBJECT_MT)
  end

  return value
end

--[[ Which backend resolved: `cjson` or `dkjson`.

  Exposed because the fallback is correct and slower, which is the kind of
  regression that hides forever -- a `lua_package_cpath` edit would demote a
  production worker to dkjson with nothing to show for it. The smoke suite
  asserts this reads `cjson`.
]]
function M.backend()
  return BACKEND
end

return M
