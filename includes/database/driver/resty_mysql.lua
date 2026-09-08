--[[ MySQL over lua-resty-mysql, bundled with OpenResty.

  Chosen in stage 8.3: 79,365 point selects a second with fifty in flight,
  against LuaDBI MySQL's 10,142.

  It has no prepared statements at all -- verified against
  `/usr/local/openresty/lualib/resty/mysql.lua` 0.27, which implements no
  `COM_STMT_PREPARE` and exposes no `prepare`. So there is nothing to bind to,
  and the layer owns the quoting. `placeholder` being nil is what tells the
  registry to compile a statement into literal chunks instead: the SQL is cut at
  its placeholders once, at compile time, and a call interleaves escaped values
  between the pieces. No request ever scans SQL.
]]

local base = require 'includes.database.driver'

local M = {
  name = 'resty-mysql',
  dialect = 'mysql',
  placeholder = nil,
  quote_identifier = base.identifier_quoter('`'),
  limit_clause = ' LIMIT ?, ?',
}

local concat = table.concat

function M.connect(config)
  local mysql = require 'resty.mysql'
  local db, err = mysql:new()

  if not db then
    return nil, err
  end

  db:set_timeout(tonumber(config.timeout) or 5000)

  local ok, connect_err = db:connect{
    host = config.host or '127.0.0.1',
    port = tonumber(config.port) or 3306,
    database = config.database,
    user = config.username,
    password = config.password,
    charset = config.charset or 'utf8mb4',
    pool = config.pool or config.name,
    pool_size = config.pool_size,
  }

  if not ok then
    return nil, connect_err
  end

  return db
end

--[[ One escaper, audited, in one place.

  `ngx.quote_sql_str` handles the string case and is the reason this is safe at
  all: it is nginx's own escaper, not a gsub written here. Numbers do not go
  through it -- it would quote them into strings -- so they take the integer
  path for the reason spelled out in `includes/database/driver/init.lua`.

  `ngx` is read here rather than captured at the top of the file on purpose:
  `tests/unit/test_query_layer.lua` requires this module under plain `lua5.1` to
  compile statements for the MySQL dialect, where there is no `ngx` to capture
  and nothing that escapes anything.
]]
function M.escape(value)
  local kind = type(value)

  if value == nil or value == ngx.null then
    return 'NULL'
  elseif kind == 'number' then
    return base.number_literal(value)
  elseif kind == 'boolean' then
    return value and 'TRUE' or 'FALSE'
  end

  return ngx.quote_sql_str(tostring(value))
end

--[[ Build the statement from its compiled template and the call's values.

  `string.format` rather than concatenation of chunks, because it measured
  faster: 126 ns against 344 on one parameter, 988 against 1279 on five. It
  sizes and fills one buffer, where the chunk path allocates a table, fills it
  and then concatenates it.

  The arity is dispatched rather than collected into a table, so nothing is
  allocated for the parameters themselves. Five covers everything the codebase
  issues -- the widest statements in it are the content and user updates, at six
  including the id, which is why the table falls back rather than stopping at
  five.
]]
local function assemble(compiled, a, b, c, d, e)
  local template = compiled.template
  local n = compiled.nparams

  if n == 1 then
    return template:format(M.escape(a))
  elseif n == 2 then
    return template:format(M.escape(a), M.escape(b))
  elseif n == 3 then
    return template:format(M.escape(a), M.escape(b), M.escape(c))
  elseif n == 4 then
    return template:format(M.escape(a), M.escape(b), M.escape(c), M.escape(d))
  elseif n == 5 then
    return template:format(M.escape(a), M.escape(b), M.escape(c), M.escape(d),
      M.escape(e))
  end

  return nil
end

-- Beyond the dispatch above, which no statement in the codebase reaches today.
local function assemble_wide(compiled, ...)
  local chunks = compiled.chunks
  local out = {chunks[1]}

  for i = 1, compiled.nparams do
    out[#out + 1] = M.escape((select(i, ...)))
    out[#out + 1] = chunks[i + 1]
  end

  return concat(out)
end

-- Exported so `tests/bench/layer_bench.lua` can measure the two forms against
-- each other. The choice between them was made by that measurement, so it needs
-- to stay reproducible.
M.assemble = assemble
M.assemble_wide = assemble_wide

function M.execute(handle, compiled, ...)
  local sql, res, err

  if compiled.nparams == 0 then
    -- The whole body, with no `%` doubled into it; the template is for `format`
    -- and this path does not go through `format`.
    sql = compiled.chunks[1]
  else
    sql = assemble(compiled, ...) or assemble_wide(compiled, ...)
  end

  res, err = handle:query(sql)

  if res == nil then
    return nil, err
  end

  return res
end

function M.release(handle, ok)
  if ok then
    local pooled = handle:set_keepalive()

    if pooled then
      return true
    end
  end

  pcall(function() handle:close() end)

  return false
end

--[[ `ngx.null` is not nil and is not `empty()`.

  Every call site in the codebase reads an absent column as nil, which is what
  pgmoon, LuaSQL and LuaDBI's PostgreSQL and SQLite drivers give. This one gives
  a sentinel, so it is normalized here rather than at sixty-three call sites.
  The pass is per column rather than per query, so its cost scales with result
  size -- which is why the bench measures it on a 100-row select and not only on
  a point lookup.
]]
function M.rows(res)
  local null = ngx.null

  for i = 1, #res do
    local row = res[i]

    for key, value in pairs(row) do
      if value == null then
        row[key] = nil
      end
    end
  end

  return res
end

return M
