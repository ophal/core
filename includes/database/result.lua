--[[ The application's contract over whatever a driver hands back.

  Phase 1 introduced this so framework code stopped passing raw LuaDBI handles
  around as if they were Ophal's own type. It now spans two shapes, because the
  drivers stage 8.3 chose do not agree on one:

  - LuaDBI answers a query with a **statement handle**, and rows are pulled from
    it one at a time, positionally or by name.
  - pgmoon and lua-resty-mysql answer with the **rows themselves**, already
    built, as a list of tables keyed by column name.

  Both arrive here and both read the same way. What the second shape cannot do
  is answer positionally -- a hash row has no first column, and
  `lua-resty-mysql` has no other result mode to ask for. So the query layer
  takes its results through `M.named()`, which refuses a positional read on
  every backend: a call site written as `(rs:fetch() or {})[1]` then fails on
  SQLite in the unit suite rather than on PostgreSQL in production.
]]

local M = {}

local Result = {}
Result.__index = Result

local NAMED_ONLY = 'rows here are named: read them with fetch(true) or '
  .. 'rows(true) and take the column by name, giving it an alias in the '
  .. 'statement if it has none'

local function normalize_named(named)
  if named then
    return true
  end
end

local function is_wrapper(value)
  return getmetatable(value) == Result
end

--[[ Whether a raw yields rows on demand, which LuaDBI's statement handle does
  and a built list does not.

  LuaDBI's handle is **userdata**, not a table -- its methods are reached
  through a metatable -- so a test for a table would send every LuaDBI result
  down the list path and read nil from it. That is not hypothetical either: this
  function said `type(raw) == 'table'` for one revision, and
  `tests/bench/driver_contract.lua` failed on SQLite at the first row.
]]
local function pulls_rows(raw)
  local kind = type(raw)

  if kind ~= 'table' and kind ~= 'userdata' then
    return false
  end

  return type(raw.fetch) == 'function'
    or type(raw.fetch_one) == 'function'
    or type(raw.rows) == 'function'
end

local function require_named(self, named)
  if not named and (self._list or self._named) then
    error('database result: ' .. NAMED_ONLY, 0)
  end
end

local function raw_fetch(raw, named)
  if type(raw.fetch) == 'function' then
    return raw:fetch(normalize_named(named))
  elseif type(raw.fetch_one) == 'function' then
    return raw:fetch_one(named and true or false)
  end

  error('database result does not implement fetch semantics')
end

function Result:fetch(named)
  local index

  require_named(self, named)

  if not self._list then
    return raw_fetch(self._raw, named)
  end

  -- The cursor belongs to the Result rather than to the list, so `fetch` and
  -- `rows` interleave over a built list exactly as they do over a handle.
  index = self._cursor + 1
  self._cursor = index

  return self._raw[index]
end

function Result:rows(named)
  require_named(self, named)

  if self._list or type(self._raw.fetch) == 'function'
      or type(self._raw.fetch_one) == 'function' then
    return function()
      return self:fetch(named)
    end
  end

  return self._raw:rows(normalize_named(named))
end

--[[ Every row that has not been taken yet.

  A driver that built the list already hands it over rather than having it
  copied. `modules/content`'s front page and `modules/tag`'s menu each read a
  whole projection row set this way and then cache it, so the copy would be a
  second pass over every row to produce a table indistinguishable from the one
  discarded. It is only handed over untouched when nothing has been fetched from
  it, since otherwise the rows already taken would come back a second time.
]]
function Result:all(named)
  local items

  require_named(self, named)

  if self._list and self._cursor == 0 then
    self._cursor = #self._raw

    return self._raw
  end

  items = {}

  for row in self:rows(named) do
    items[#items + 1] = row
  end

  return items
end

function Result:close()
  if not self._list and type(self._raw.close) == 'function' then
    return self._raw:close()
  end

  return true
end

function Result:raw()
  return self._raw
end

--[[ Wrap a driver's answer, in whichever of the two shapes it came.

  The shape is decided here rather than per row: a raw with `fetch`, `fetch_one`
  or `rows` yields rows on demand, and anything else is the list itself. A
  driver hands back a table either way -- `includes/database/driver/init.lua`
  says so -- because a query that produced no rows is an empty list, not a
  boolean.
]]
function M.wrap(raw)
  if raw == nil then
    return nil
  elseif is_wrapper(raw) then
    return raw
  elseif pulls_rows(raw) then
    return setmetatable({_raw = raw}, Result)
  end

  return setmetatable({_raw = raw, _list = true, _cursor = 0}, Result)
end

--[[ The query layer's result: named rows, on every backend.

  Two of the three drivers cannot answer positionally at all, so the layer
  promises only what all of them can keep. Marking it here rather than letting
  the list shape refuse on its own is what makes the refusal uniform: the same
  call site fails the same way on SQLite, which is the backend the unit and
  smoke suites run against.
]]
function M.named(raw)
  local wrapped = M.wrap(raw)

  if wrapped ~= nil then
    wrapped._named = true
  end

  return wrapped
end

M.Result = Result

return M
