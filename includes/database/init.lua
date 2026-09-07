dbh = {} -- Database handlers kept global for compatibility during DB boundary work

-- OpenResty note:
-- Ophal 0.2.x still uses synchronous LuaDBI calls. Every connect, prepare,
-- and execute blocks the current OpenResty worker until the driver returns.
-- This runtime model is supported for low-to-moderate traffic, but it is not
-- a fully nonblocking database stack.
local DBI, db_id, drivers = require 'DBI', 'default', {}
local db_result = require 'includes.database.result'
local db_stats = require 'includes.database.stats'
local xtable = seawolf.contrib.seawolf_table

function db_set_db_id(id)
  db_id = id
end

function db_connection(id)
  local key = id or db_id

  if key == nil then
    return nil
  end

  return dbh[key]
end

function db_connect()
  local err, driver
  local connection = settings.db[db_id]

  if connection == nil then return end

  if not connection.autocommit then connection.autocommit = true end

  -- Bootstrap connects once per request, so without this the previous
  -- request's handle is dropped rather than closed and stays open until the
  -- collector happens to run. On SQLite that is not merely untidy: a dropped
  -- connection whose last statement was never finalized still holds a read
  -- transaction, and it blocks every later writer -- including the projection
  -- rebuilds that Phase 3 made reachable from a GET.
  if dbh[db_id] ~= nil then
    pcall(function()
      dbh[db_id]:close()
    end)
    dbh[db_id] = nil
  end

  dbh[db_id], err = DBI.Connect(
    connection.driver,
    connection.database,
    connection.username,
    connection.password,
    connection.host,
    connection.port
  )

  if err then
    if type(log_error) == 'function' then
      log_error('database connection failed', {
        event = 'database_connection_failed',
        database = connection.database,
        driver = connection.driver,
        host = connection.host,
      })
    end
    error(err)
  end

  drivers[db_id] = require('includes.database.' .. connection.driver:lower())

  -- commit the transaction
  dbh[db_id]:autocommit(connection.autocommit)

  -- Per-driver connection setup. SQLite uses this to widen its locking
  -- defaults, which multi-worker OpenResty needs and the driver defaults do
  -- not give; drivers without connection state simply omit the hook.
  --
  -- This runs after autocommit is set, not before. LuaDBI opens a transaction
  -- on connect, and SQLite refuses `PRAGMA journal_mode = WAL` from inside one
  -- with "cannot change into wal mode from within a transaction". The pragma
  -- helper logs that failure and continues, so running the hook first left the
  -- database in rollback mode while reporting success -- the one mode the
  -- Phase 3 rebuild-inside-a-GET path needs it not to be in.
  if type(drivers[db_id].on_connect) == 'function' then
    drivers[db_id].on_connect(connection)
  end

  -- check status of the connection
  return dbh[db_id]:ping()
end

function db_query(query, ...)
  local err, sth
  local connection = db_connection()

  if connection == nil then
    if type(log_error) == 'function' then
      log_error('database query without connection', {
        event = 'database_query_without_connection',
      })
    end
    error 'No database connection'
  end

  db_stats.record(query)

  -- prepare a query
  sth, err = connection:prepare(query)
  if err or nil == sth then
    if type(log_error) == 'function' then
      log_error('database prepare failed', {
        event = 'database_prepare_failed',
        error = err,
        query = query,
      })
    end
    error(err or 'Database prepare failed')
  end

  -- execute select with a bind variable
  _, err = sth:execute(...)

  if err then
    if type(log_error) == 'function' then
      log_error('database execute failed', {
        event = 'database_execute_failed',
        error = err,
        query = query,
      })
    end
    error(err)
  end

  return db_result.wrap(sth)
end

-- Reports how many queries this worker has issued and how many of them still
-- read normalized tables. Public delivery should hold `normalized` at zero once
-- the worker is warm; anything else names the path that still falls through.
function db_query_stats()
  return db_stats.snapshot()
end

function db_query_stats_reset()
  db_stats.reset()
end

function db_last_insert_id(...)
  return drivers[db_id].last_insert_id(...)
end

function db_limit()
  return drivers[db_id].limit()
end

function db_table_schema_sql()
  return drivers[db_id].table_schema_sql()
end

local schema_cache = {}

function db_schema_cache_clear()
  schema_cache = {}
end

function db_field(tbl_name, field_name)
  if schema_cache[tbl_name] then
    return schema_cache[tbl_name][field_name]
  end

  local rs, err = db_query(db_table_schema_sql(), tbl_name)

  local res = xtable()

  for row in rs:rows(true) do
    res[row.field_name] = row.field_name
  end

  schema_cache[tbl_name] = res

  return res[field_name]
end
