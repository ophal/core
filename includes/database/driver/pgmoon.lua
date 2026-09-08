--[[ PostgreSQL over pgmoon, on OpenResty cosockets.

  Chosen in stage 8.3: 45,045 point selects a second with fifty in flight,
  against LuaDBI PostgreSQL's 6,784. A blocking driver holds the worker for the
  whole round trip, so it cannot overlap; that flat line is the entire case for
  cosockets.

  Two pgmoon behaviours are corrected here rather than lived with.
]]

local base = require 'includes.database.driver'

local M = {
  name = 'pgmoon',
  dialect = 'postgresql',
  placeholder = 'numbered',
  quote_identifier = base.identifier_quoter('"'),
  limit_clause = ' OFFSET ? LIMIT ?',
}

local INT8 = 20
local NUMERIC = 1700

--[[ Send whole numbers as int8.

  pgmoon serializes every Lua number as OID 1700, `numeric`. `WHERE id = $1`
  then reaches PostgreSQL as `(id)::numeric = '5'::numeric`, which coerces the
  *column*: EXPLAIN shows a sequential scan, and a primary-key lookup on a
  7,000-row table measured 835 us against 50 us. Nothing errors and the query
  count is unchanged, so every budget in the smoke suite would have stayed green
  while every point lookup in the codebase became a table scan.

  This is the fix, and it is the only reason the bound path is usable at all.
  It restores the index scan and takes that lookup to 73 us.
]]
local function install_serializers(pg)
  local serializers = pg.type_serializers or {}

  -- Both halves go through `base.number_literal`, which is the same escaper the
  -- literal path uses. pgmoon's own serializer wrote the fractional case with
  -- `tostring` as well, so a number too long for `%.14g` was truncated on its
  -- way into a `numeric` column too -- less loudly than the OID, and by the
  -- same mistake.
  serializers.number = function(_, value)
    return base.is_integer(value) and INT8 or NUMERIC,
      base.number_literal(value)
  end

  pg.type_serializers = serializers

  return pg
end

function M.connect(config)
  local pgmoon = require 'pgmoon'
  local pg = pgmoon.new{
    host = config.host or '127.0.0.1',
    port = tonumber(config.port) or 5432,
    database = config.database,
    user = config.username,
    password = config.password,
    socket_type = config.socket_type or (ngx and 'nginx' or 'luasocket'),
    pool = config.pool or config.name,
    pool_size = config.pool_size,
  }

  local ok, err = pg:connect()

  if not ok then
    return nil, err
  end

  return install_serializers(pg)
end

--[[ Escaping, for the statements that opt out of binding.

  pgmoon's own `escape_literal` is deliberately not called: it sends numbers
  through `tostring`, which loses integer precision past fourteen digits. See
  `includes/database/driver/init.lua`.
]]
function M.escape(value)
  local kind = type(value)

  if value == nil then
    return 'NULL'
  elseif kind == 'number' then
    return base.number_literal(value)
  elseif kind == 'boolean' then
    return value and 'TRUE' or 'FALSE'
  end

  return "'" .. tostring(value):gsub("'", "''") .. "'"
end

function M.execute(handle, compiled, ...)
  local res, err

  if compiled.nparams > 0 then
    res, err = handle:query(compiled.sql, ...)
  else
    res, err = handle:query(compiled.sql)
  end

  if res == nil then
    return nil, err
  end

  return res
end

--[[ Back to the pool on success, closed on failure.

  A connection whose last statement errored may have a live transaction or
  unread protocol traffic, so it is never pooled. pgmoon's `keepalive()` does
  issue a ROLLBACK when `transaction_status` is `T` or `E`, but that is a repair
  of a broken invariant rather than the invariant: the layer's `transaction()`
  is what makes the state known before this is reached.
]]
function M.release(handle, ok)
  if ok and handle.keepalive then
    local pooled = handle:keepalive()

    if pooled then
      return true
    end
  end

  pcall(function() handle:disconnect() end)

  return false
end

--[[ pgmoon returns rows as a list of hashes, with SQL NULL absent -- which is
  nil, and is what every call site already assumes. So there is nothing to
  normalize per row.

  What does need normalizing is the answer to a statement that produced no rows
  at all: pgmoon returns `true` for an INSERT or an UPDATE without RETURNING,
  and the layer's contract is a list. Nothing reads an affected-row count
  anywhere in the codebase, so it is dropped rather than carried.
]]
function M.rows(res)
  if res == true then
    return {}
  end

  return res
end

return M
