--[[ One adapter per candidate driver, all answering the same four questions.

  Each adapter writes its own SQL. That is deliberate: the point of the exercise
  is to compare drivers doing what each is best at, so pgmoon binds `$1` where
  `lua-resty-mysql` interpolates through `ngx.quote_sql_str` and LuaDBI prepares
  a `?` statement. A harness that forced one dialect on all of them would be
  measuring the dialect.

  `null` reports how the driver hands back a SQL NULL, because that is the
  difference most likely to break `empty()` at a call site rather than to show
  up in a number.
]]

local M = {}

local config = {
  pg = {host = '127.0.0.1', port = 15432, database = 'ophal_bench', user = 'ophal', password = 'ophal'},
  mysql = {host = '127.0.0.1', port = 13306, database = 'ophal_bench', user = 'ophal', password = 'ophal'},
  sqlite = {database = os.getenv('OPHAL_BENCH_SQLITE') or '/tmp/ophal_bench.sqlite'},
}

M.config = config

local function first_row(rows)
  if type(rows) ~= 'table' then
    return nil
  end

  return rows[1]
end

--[[ How this driver hands back a SQL NULL.

  The probe reads a nullable column of a real row rather than `SELECT NULL`,
  partly because that is the shape a call site meets and partly because
  `SELECT NULL AS nothing` is a syntax error on SQLite: NOTHING is a keyword
  there, from `ON CONFLICT DO NOTHING`.

  This matters more than any of the timings. `empty()` is called on column
  values all over the codebase, and a sentinel table or an `ngx.null` is not
  empty -- so a driver that reports one has to be normalised in its adapter,
  not at the call sites.
]]
function M.describe_null(row)
  if row == nil then
    return 'no row'
  elseif row.note == nil then
    return 'nil (or key absent)'
  elseif ngx and row.note == ngx.null then
    return 'ngx.null'
  elseif type(row.note) == 'table' then
    return 'sentinel table'
  end

  return ('%s %q'):format(type(row.note), tostring(row.note))
end

-- ---------------------------------------------------------------- pgmoon ----

--[[ Send whole Lua numbers as int8 rather than as numeric.

  pgmoon's stock `number` serializer returns OID 1700, so `WHERE id = $1`
  reaches PostgreSQL as `(id)::numeric = '5'::numeric`. That is a coercion of
  the *column*, so no integer index can serve it and the planner falls back to a
  sequential scan -- measured at 835 us against 50 us for the same lookup with
  an escaped literal, on a 7000-row table. Nothing errors and the query count
  does not change, which is exactly why it would survive this codebase's
  budgets unnoticed.

  Overriding one serializer restores the index scan. It is here as its own
  candidate rather than folded into the pgmoon adapter because the difference
  between the two is the finding.
]]
local function int8_serializers(pg)
  local serializers = {}

  for name, fn in pairs(pg.type_serializers) do
    serializers[name] = fn
  end

  serializers.number = function(_, v)
    if v % 1 == 0 and v >= -9223372036854775808 and v <= 9223372036854775807 then
      return 20, ('%d'):format(v)
    end

    return 1700, tostring(v)
  end

  return serializers
end

local function pgmoon_adapter(name, mode, fix_numbers)
  local pgmoon = require 'pgmoon'
  local pg

  return {
    name = name,
    backend = 'postgresql',
    blocking = false,

    connect = function()
      pg = pgmoon.new(config.pg)
      local ok, err = pg:connect()
      if not ok then
        return nil, err
      end
      if fix_numbers then
        pg.type_serializers = int8_serializers(pg)
      end
      return true
    end,

    ddl = function(sql)
      return pg:query(sql)
    end,

    point = function(id)
      if mode == 'extended' then
        return first_row(pg:query('SELECT id, title, body FROM bench_rows WHERE id = $1', id))
      end
      return first_row(pg:query(
        'SELECT id, title, body FROM bench_rows WHERE id = ' .. pg:escape_literal(id)))
    end,

    page = function(limit)
      if mode == 'extended' then
        return pg:query('SELECT id, title, body FROM bench_rows ORDER BY id LIMIT $1', limit)
      end
      return pg:query(
        'SELECT id, title, body FROM bench_rows ORDER BY id LIMIT ' .. pg:escape_literal(limit))
    end,

    insert = function(title)
      if mode == 'extended' then
        return pg:query('INSERT INTO bench_rows(title, body) VALUES ($1, $2)', title, 'body')
      end
      return pg:query(('INSERT INTO bench_rows(title, body) VALUES (%s, %s)'):format(
        pg:escape_literal(title), pg:escape_literal('body')))
    end,

    update = function(id, title)
      if mode == 'extended' then
        return pg:query('UPDATE bench_rows SET title = $1 WHERE id = $2', title, id)
      end
      return pg:query(('UPDATE bench_rows SET title = %s WHERE id = %s'):format(
        pg:escape_literal(title), pg:escape_literal(id)))
    end,

    null = function()
      local row = first_row(pg:query('SELECT id, note FROM bench_rows WHERE id = 1'))
      return M.describe_null(row)
    end,

    close = function()
      if pg then pg:disconnect() end
    end,
  }
end

-- ---------------------------------------------------------- lua-resty-mysql --

local function resty_mysql_adapter()
  local mysql = require 'resty.mysql'
  local db

  --[[ `lua-resty-mysql` binds nothing, so every value is interpolated through
    `ngx.quote_sql_str`. Numbers are passed through unquoted rather than sent as
    strings: MySQL rejects `LIMIT '100'` outright, and a quoted integer in a
    `WHERE` is a coercion the server should not have to do.
  ]]
  local function literal(value)
    if type(value) == 'number' then
      return tostring(value)
    end

    return ngx.quote_sql_str(tostring(value))
  end

  return {
    name = 'lua-resty-mysql',
    backend = 'mysql',
    blocking = false,

    connect = function()
      db = mysql:new()
      db:set_timeout(5000)
      local ok, err = db:connect(config.mysql)
      if not ok then
        return nil, err
      end
      return true
    end,

    ddl = function(sql)
      return db:query(sql)
    end,

    point = function(id)
      return first_row(db:query(
        'SELECT id, title, body FROM bench_rows WHERE id = ' .. literal(id)))
    end,

    page = function(limit)
      return db:query(
        'SELECT id, title, body FROM bench_rows ORDER BY id LIMIT ' .. literal(limit))
    end,

    insert = function(title)
      return db:query(('INSERT INTO bench_rows(title, body) VALUES (%s, %s)'):format(
        literal(title), literal('body')))
    end,

    update = function(id, title)
      return db:query(('UPDATE bench_rows SET title = %s WHERE id = %s'):format(
        literal(title), literal(id)))
    end,

    null = function()
      local row = first_row(db:query('SELECT id, note FROM bench_rows WHERE id = 1'))
      return M.describe_null(row)
    end,

    close = function()
      if db then db:close() end
    end,
  }
end

-- ---------------------------------------------------------------- LuaDBI ----

local function luadbi_adapter(name, driver, backend)
  local DBI = require 'DBI'
  local dbh

  local function run(sql, ...)
    local sth, err = dbh:prepare(sql)
    if not sth then
      error(tostring(err) .. ' :: ' .. sql)
    end
    local ok
    ok, err = sth:execute(...)
    if not ok then
      error(tostring(err) .. ' :: ' .. sql)
    end
    return sth
  end

  local function rows_of(sth)
    local out = {}
    for row in sth:rows(true) do
      out[#out + 1] = row
    end
    return out
  end

  return {
    name = name,
    backend = backend,
    blocking = true,

    connect = function()
      local settings = config[backend == 'postgresql' and 'pg'
        or backend == 'mysql' and 'mysql' or 'sqlite']
      local err
      dbh, err = DBI.Connect(driver, settings.database, settings.user,
        settings.password, settings.host, settings.port)
      if not dbh then
        return nil, err
      end
      dbh:autocommit(true)
      return true
    end,

    ddl = function(sql)
      return run(sql)
    end,

    point = function(id)
      return run('SELECT id, title, body FROM bench_rows WHERE id = ?', id):fetch(true)
    end,

    page = function(limit)
      return rows_of(run('SELECT id, title, body FROM bench_rows ORDER BY id LIMIT ?', limit))
    end,

    insert = function(title)
      return run('INSERT INTO bench_rows(title, body) VALUES (?, ?)', title, 'body')
    end,

    update = function(id, title)
      return run('UPDATE bench_rows SET title = ? WHERE id = ?', title, id)
    end,

    null = function()
      return M.describe_null(run('SELECT id, note FROM bench_rows WHERE id = ?', 1):fetch(true))
    end,

    close = function()
      if dbh then dbh:close() end
    end,
  }
end

-- ---------------------------------------------------------------- LuaSQL ----

local function luasql_adapter(name, module_name, backend)
  local luasql = require('luasql.' .. module_name)
  local envh, conn

  local function escape(value)
    if type(value) == 'number' then
      return tostring(value)
    end
    return "'" .. conn:escape(tostring(value)) .. "'"
  end

  local function rows_of(cur)
    local out = {}

    if type(cur) ~= 'userdata' then
      return out
    end

    local row = cur:fetch({}, 'a')
    while row do
      local copy = {}
      for k, v in pairs(row) do copy[k] = v end
      out[#out + 1] = copy
      row = cur:fetch(row, 'a')
    end
    cur:close()
    return out
  end

  return {
    name = name,
    backend = backend,
    blocking = true,

    connect = function()
      local settings = config[backend == 'postgresql' and 'pg'
        or backend == 'mysql' and 'mysql' or 'sqlite']
      envh = luasql[module_name]()
      local err
      if backend == 'sqlite' then
        conn, err = envh:connect(settings.database)
      else
        conn, err = envh:connect(settings.database, settings.user, settings.password,
          settings.host, settings.port)
      end
      if not conn then
        return nil, err
      end
      return true
    end,

    ddl = function(sql)
      return conn:execute(sql)
    end,

    point = function(id)
      return rows_of(conn:execute('SELECT id, title, body FROM bench_rows WHERE id = ' .. escape(id)))[1]
    end,

    page = function(limit)
      return rows_of(conn:execute('SELECT id, title, body FROM bench_rows ORDER BY id LIMIT ' .. escape(limit)))
    end,

    insert = function(title)
      return conn:execute(('INSERT INTO bench_rows(title, body) VALUES (%s, %s)'):format(
        escape(title), escape('body')))
    end,

    update = function(id, title)
      return conn:execute(('UPDATE bench_rows SET title = %s WHERE id = %s'):format(
        escape(title), escape(id)))
    end,

    null = function()
      return M.describe_null(rows_of(conn:execute('SELECT id, note FROM bench_rows WHERE id = 1'))[1])
    end,

    close = function()
      if conn then conn:close() end
      if envh then envh:close() end
    end,
  }
end

-- -------------------------------------------------------------- lsqlite3 ----

--[[ The direct SQLite binding, with and without statement caching.

  SQLite has no socket, so no binding for it can ever be non-blocking and the
  only thing on offer is per-call overhead. `cached` is the interesting half:
  unlike LuaDBI, which calls `prepare()` on every query and throws the handle
  away, lsqlite3 lets a statement be prepared once and re-bound -- which is
  exactly what a compile-once query layer would do with it.
]]
local function lsqlite3_adapter(name, cached)
  local sqlite3 = require 'lsqlite3'
  local db
  local statements = {}

  local function statement(sql)
    -- `cached and statements[sql]` is false, not nil, when caching is off.
    local stmt = cached and statements[sql] or nil

    if stmt == nil then
      stmt = assert(db:prepare(sql), db:errmsg())
      if cached then
        statements[sql] = stmt
      end
    else
      stmt:reset()
    end

    return stmt
  end

  local function release(stmt)
    if cached then
      stmt:reset()
    else
      stmt:finalize()
    end
  end

  local function rows_of(sql, ...)
    local stmt = statement(sql)
    local out = {}

    stmt:bind_values(...)

    while stmt:step() == sqlite3.ROW do
      out[#out + 1] = stmt:get_named_values()
    end

    release(stmt)

    return out
  end

  local function run(sql, ...)
    local stmt = statement(sql)

    stmt:bind_values(...)
    stmt:step()
    release(stmt)

    return true
  end

  return {
    name = name,
    backend = 'sqlite',
    blocking = true,

    connect = function()
      local err
      db, err = sqlite3.open(config.sqlite.database)
      if not db then
        return nil, err
      end
      return true
    end,

    ddl = function(sql)
      statements = {}
      return db:exec(sql)
    end,

    point = function(id)
      return rows_of('SELECT id, title, body FROM bench_rows WHERE id = ?', id)[1]
    end,

    page = function(limit)
      return rows_of('SELECT id, title, body FROM bench_rows ORDER BY id LIMIT ?', limit)
    end,

    insert = function(title)
      return run('INSERT INTO bench_rows(title, body) VALUES (?, ?)', title, 'body')
    end,

    update = function(id, title)
      return run('UPDATE bench_rows SET title = ? WHERE id = ?', title, id)
    end,

    null = function()
      return M.describe_null(rows_of('SELECT id, note FROM bench_rows WHERE id = ?', 1)[1])
    end,

    close = function()
      for _, stmt in pairs(statements) do
        stmt:finalize()
      end
      statements = {}
      if db then db:close() end
    end,
  }
end

M.candidates = {
  {id = 'pgmoon-bound', backend = 'postgresql',
    build = function() return pgmoon_adapter('pgmoon (bound $1)', 'extended') end},
  {id = 'pgmoon-bound-int8', backend = 'postgresql',
    build = function() return pgmoon_adapter('pgmoon (bound, int8 param)', 'extended', true) end},
  {id = 'pgmoon-literal', backend = 'postgresql',
    build = function() return pgmoon_adapter('pgmoon (escaped literal)', 'simple') end},
  {id = 'luadbi-pg', backend = 'postgresql',
    build = function() return luadbi_adapter('LuaDBI PostgreSQL', 'PostgreSQL', 'postgresql') end},
  {id = 'luasql-pg', backend = 'postgresql',
    build = function() return luasql_adapter('LuaSQL postgres', 'postgres', 'postgresql') end},

  {id = 'resty-mysql', backend = 'mysql', build = resty_mysql_adapter},
  {id = 'luadbi-mysql', backend = 'mysql',
    build = function() return luadbi_adapter('LuaDBI MySQL', 'MySQL', 'mysql') end},
  {id = 'luasql-mysql', backend = 'mysql',
    build = function() return luasql_adapter('LuaSQL mysql', 'mysql', 'mysql') end},

  {id = 'luadbi-sqlite', backend = 'sqlite',
    build = function() return luadbi_adapter('LuaDBI SQLite3', 'SQLite3', 'sqlite') end},
  {id = 'luasql-sqlite', backend = 'sqlite',
    build = function() return luasql_adapter('LuaSQL sqlite3', 'sqlite3', 'sqlite') end},
  {id = 'lsqlite3', backend = 'sqlite',
    build = function() return lsqlite3_adapter('lsqlite3 (prepare per call)', false) end},
  {id = 'lsqlite3-cached', backend = 'sqlite',
    build = function() return lsqlite3_adapter('lsqlite3 (cached statements)', true) end},
}

-- The bench table, per backend. `bench_rows` is deliberately small and boring:
-- the question is driver overhead, and a query whose own cost dominates would
-- hide exactly the difference being measured.
M.schema = {
  postgresql = {
    'DROP TABLE IF EXISTS bench_rows',
    [[CREATE TABLE bench_rows (
      id serial PRIMARY KEY,
      title text NOT NULL,
      body text NOT NULL,
      note text
    )]],
  },
  mysql = {
    'DROP TABLE IF EXISTS bench_rows',
    [[CREATE TABLE bench_rows (
      id INT AUTO_INCREMENT PRIMARY KEY,
      title VARCHAR(255) NOT NULL,
      body TEXT NOT NULL,
      note TEXT
    )]],
  },
  sqlite = {
    'DROP TABLE IF EXISTS bench_rows',
    [[CREATE TABLE bench_rows (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      title TEXT NOT NULL,
      body TEXT NOT NULL,
      note TEXT
    )]],
  },
}

return M
