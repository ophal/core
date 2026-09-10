--[[ One JSON layer, over OpenResty's cjson.

  Ophal runs on OpenResty and nothing else, so `cjson` is always there and this
  file does not choose a backend. What it does is hold the four places cjson's
  behaviour and this codebase's assumptions disagree, in one file, instead of at
  eight call sites:

  - **`null`.** cjson decodes it to a lightuserdata sentinel, which is neither
    `nil` nor `false` and is therefore *truthy* -- `seawolf.variable.empty`
    reports it non-empty. A body sending `{"pass": null}` would satisfy every
    presence check in the codebase and arrive at `password_verify`, at
    `secure_equals`, and at a bound SQL parameter as an opaque userdata nothing
    downstream expects. `M.decode` strips them, so a null reads as an absent
    key.
  - **The empty table.** Lua has one table type, so `{}` is both an empty list
    and an empty object and an encoder has to guess. cjson guesses object.
    `M.array()` and `M.object()` let a caller state its shape rather than
    inherit the guess -- a browser doing `for (const c of list)` throws on `{}`,
    which makes it a bug that only appears on a page with nothing on it.
  - **A nil input.** `request_get_body()` answers nil for a method with no body.
    `M.decode` refuses a non-string rather than passing it down, so the answer
    does not depend on how a particular library feels about nil.
  - **A valid scalar.** Every consumer here indexes what it gets back -- four
    request bodies and a job payload -- so `5` decoding to a number is an
    "attempt to index a number" raise rather than a wrong answer. `M.decode`
    refuses it.

  `decode` answers `value, err`. Two values, never three: the five call sites
  this replaced were written `parsed, pos, err = decode(input, 1, nil)` against
  dkjson's three, and reading two returns into three names puts the message in
  `pos` and leaves `err` nil -- which silences the guard on four parsers whose
  input is a request body.

  One thing this file deliberately does **not** do: touch
  `encode_escape_forward_slash`. cjson escapes `/` as `\/`, which is valid JSON
  and decodes identically, and that setting is shared between `cjson` and
  `cjson.safe` -- so it is VM-global state reaching every other cjson user in
  the worker. `encode_empty_table_as_object` is *not* shared, which is the trap
  in the other direction: configure the exact module you encode with.
]]

local type, pairs, setmetatable = type, pairs, setmetatable

--[[ cjson ships with OpenResty, so a failure here is not a missing rock.

  Same shape as `driver/lsqlite3.lua` and `driver/resty_mysql.lua`: name the
  thing that is actually wrong rather than dumping a search path. Ophal is an
  OpenResty application and the command line runs under `resty` for the same
  reason the worker does.
]]
local resolved, cjson = pcall(require, 'cjson.safe')

if not resolved or type(cjson) ~= 'table' or type(cjson.decode) ~= 'function' then
  error('cjson is not available. It ships with OpenResty, so this process is\n'
    .. 'probably not OpenResty -- Ophal runs its command line under resty too:\n'
    .. '  resty -c 512 ./ophal migrate apply\n'
    .. 'More: https://github.com/ophal/core', 0)
end

local NULL = cjson.null
local ARRAY_MT = cjson.empty_array_mt

local M = {}

--[[ In place. `pairs` allows clearing a field it has already visited, decoded
  JSON cannot hold a cycle, and cjson's own `decode_max_depth` bounds the
  recursion.
]]
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

--[[ Parse JSON into a table.

  Answers `table` or `nil, err`, and never raises. `cjson.safe` declines rather
  than raising, and the guards above it refuse the inputs it would accept but
  no caller here can use.
]]
function M.decode(input)
  if type(input) ~= 'string' or input == '' then
    return nil, 'no JSON input'
  end

  local value, err = cjson.decode(input)

  if err ~= nil then
    return nil, err
  end

  if type(value) ~= 'table' then
    return nil, 'expected a JSON object'
  end

  return strip_nulls(value)
end

--[[ Serialize a value as JSON.

  Answers `string` or `nil, err`, and never raises.
]]
function M.encode(value)
  local encoded, err = cjson.encode(value)

  if encoded == nil then
    return nil, err or 'cannot encode as JSON'
  end

  return encoded
end

--[[ Tag a table so an *empty* one encodes as `[]` rather than `{}`.

  The tag goes inert once the table has entries, so a collection that is
  usually populated can be tagged where it is built rather than where it turns
  out to be empty.
]]
function M.array(value)
  return setmetatable(value or {}, ARRAY_MT)
end

--[[ And the other way: a table that must encode as `{}`.

  There is nothing to apply -- an empty table is already an object to cjson --
  so this states the intent at the call site and returns the table unchanged.
  It deliberately does not clear an existing metatable: the call sites tag
  tables they did not create.
]]
function M.object(value)
  return value or {}
end

--[[ The backend, which is always `cjson`.

  Kept because the smoke suite asserts it, and what that assertion is really
  about is that the worker is a real OpenResty with its bundled libraries
  reachable -- a `lua_package_cpath` edit is all it takes to break that, and
  everything else about the site would go on working.
]]
function M.backend()
  return 'cjson'
end

return M
