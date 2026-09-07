-- Unit tests for the database result wrapper and db_query() boundary.

local db_result = require 'includes.database.result'

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

local function assert_truthy(label, got)
  assert_eq(label, got and true or false, true)
end

local function new_fake_result()
  local rows = {
    {1, 'alpha'},
    {2, 'beta'},
  }
  local named_rows = {
    {id = 1, name = 'alpha'},
    {id = 2, name = 'beta'},
  }

  return {
    index = 0,
    closed = false,
    fetch = function(self, named)
      self.index = self.index + 1
      if named then
        return named_rows[self.index]
      end
      return rows[self.index]
    end,
    close = function(self)
      self.closed = true
      return true
    end,
  }
end

io.write '\n-- database result wrapper --\n'

do
  local raw = new_fake_result()
  local wrapped = db_result.wrap(raw)
  local row = wrapped:fetch()

  assert_eq('wrap_fetch_first_value', row[2], 'alpha')
  assert_eq('wrap_raw_identity', wrapped:raw(), raw)
end

do
  local wrapped = db_result.wrap(new_fake_result())
  local row = wrapped:fetch(true)

  assert_eq('wrap_fetch_named_id', row.id, 1)
  assert_eq('wrap_fetch_named_name', row.name, 'alpha')
end

do
  local wrapped = db_result.wrap(new_fake_result())
  local names = {}

  for row in wrapped:rows(true) do
    names[#names + 1] = row.name
  end

  assert_eq('wrap_rows_count', #names, 2)
  assert_eq('wrap_rows_first_name', names[1], 'alpha')
  assert_eq('wrap_rows_second_name', names[2], 'beta')
end

do
  local wrapped = db_result.wrap(new_fake_result())
  local rows = wrapped:all(true)

  assert_eq('wrap_all_count', #rows, 2)
  assert_eq('wrap_all_second_id', rows[2].id, 2)
end

do
  local wrapped = db_result.wrap(new_fake_result())
  local wrapped_again = db_result.wrap(wrapped)

  assert_eq('wrap_idempotent', wrapped_again, wrapped)
end

do
  local raw = new_fake_result()
  local wrapped = db_result.wrap(raw)

  assert_truthy('wrap_close_delegates', wrapped:close())
  assert_eq('wrap_close_marks_raw', raw.closed, true)
end

io.write '\n-- db query boundary --\n'

do
  local saved_settings = settings
  local saved_log_error = log_error
  local saved_seawolf = seawolf
  local saved_dbh = dbh
  local saved_db_set_db_id = db_set_db_id
  local saved_db_connect = db_connect
  local saved_db_query = db_query
  local saved_db_connection = db_connection
  local saved_db_last_insert_id = db_last_insert_id
  local saved_db_limit = db_limit
  local saved_db_table_schema_sql = db_table_schema_sql
  local saved_db_schema_cache_clear = db_schema_cache_clear
  local saved_db_field = db_field
  local saved_dbi = package.loaded.DBI
  local saved_sqlite_driver = package.loaded['includes.database.sqlite3']
  local prepared_query

  package.loaded.DBI = {
    Connect = function()
      return {
        autocommit = function() end,
        ping = function() return true end,
        prepare = function(_, query)
          prepared_query = query
          return {
            execute = function() return true end,
            fetch = function(_, named)
              if named then
                return {value = 'wrapped'}
              end
              return {'wrapped'}
            end,
          }
        end,
      }
    end,
  }

  package.loaded['includes.database.sqlite3'] = {
    last_insert_id = function() return 1 end,
    limit = function() return ' LIMIT ?, ?' end,
    table_schema_sql = function() return 'SELECT field_name FROM mock' end,
  }

  seawolf = {
    contrib = {
      seawolf_table = function()
        return {}
      end,
    },
  }
  settings = {
    db = {
      default = 'default',
      default = {
        driver = 'SQLite3',
        database = ':memory:',
        autocommit = true,
      },
    },
  }
  log_error = function() end

  dofile('includes/database/init.lua')

  db_set_db_id('default')
  assert_truthy('db_connect_ping', db_connect())

  local rs = db_query('SELECT 1')
  local row = rs:fetch(true)

  assert_eq('db_query_prepared_query', prepared_query, 'SELECT 1')
  assert_eq('db_query_returns_wrapper', getmetatable(rs), db_result.Result)
  assert_eq('db_query_fetch_named_value', row.value, 'wrapped')
  assert_truthy('db_connection_accessor', db_connection('default'))

  settings = saved_settings
  log_error = saved_log_error
  seawolf = saved_seawolf
  dbh = saved_dbh
  db_set_db_id = saved_db_set_db_id
  db_connect = saved_db_connect
  db_query = saved_db_query
  db_connection = saved_db_connection
  db_last_insert_id = saved_db_last_insert_id
  db_limit = saved_db_limit
  db_table_schema_sql = saved_db_table_schema_sql
  db_schema_cache_clear = saved_db_schema_cache_clear
  db_field = saved_db_field
  package.loaded.DBI = saved_dbi
  package.loaded['includes.database.sqlite3'] = saved_sqlite_driver
end

io.write '\n-- connection lifecycle --\n'

-- Bootstrap connects once per request, so a handle that is replaced rather than
-- closed stays open until the collector runs. On SQLite that is not just a leak:
-- a dropped connection whose last statement was never finalized keeps a read
-- transaction open, which blocks writers and stops WAL from checkpointing.
do
  local saved_settings = settings
  local saved_log_error = log_error
  local saved_seawolf = seawolf
  local saved_dbh = dbh
  local saved_db_set_db_id = db_set_db_id
  local saved_db_connect = db_connect
  local saved_db_query = db_query
  local saved_db_connection = db_connection
  local saved_db_last_insert_id = db_last_insert_id
  local saved_db_limit = db_limit
  local saved_db_table_schema_sql = db_table_schema_sql
  local saved_db_schema_cache_clear = db_schema_cache_clear
  local saved_db_field = db_field
  local saved_dbi = package.loaded.DBI
  local saved_sqlite_driver = package.loaded['includes.database.sqlite3']
  local connects, closes = 0, 0
  local calls = {}

  package.loaded.DBI = {
    Connect = function()
      connects = connects + 1
      return {
        id = connects,
        autocommit = function()
          calls[#calls + 1] = 'autocommit'
        end,
        ping = function() return true end,
        close = function()
          closes = closes + 1
          return true
        end,
        prepare = function()
          return {execute = function() return true end}
        end,
      }
    end,
  }

  package.loaded['includes.database.sqlite3'] = {
    last_insert_id = function() return 1 end,
    limit = function() return ' LIMIT ?, ?' end,
    table_schema_sql = function() return 'SELECT field_name FROM mock' end,
    on_connect = function()
      calls[#calls + 1] = 'on_connect'
    end,
  }

  seawolf = {
    contrib = {
      seawolf_table = function()
        return {}
      end,
    },
  }
  settings = {
    db = {
      default = {
        driver = 'SQLite3',
        database = ':memory:',
        autocommit = true,
      },
    },
  }
  log_error = function() end

  dofile('includes/database/init.lua')
  db_set_db_id('default')

  db_connect()
  assert_eq('db_connect_first_opens_nothing_to_close', closes, 0)
  assert_eq('db_connect_first_handle', db_connection('default').id, 1)

  -- LuaDBI opens a transaction on connect, and SQLite refuses to change the
  -- journal mode from inside one. Running the driver hook before autocommit is
  -- set therefore lost the WAL pragma to a logged, non-fatal failure.
  assert_eq('db_connect_autocommit_first', calls[1], 'autocommit')
  assert_eq('db_connect_pragmas_second', calls[2], 'on_connect')

  db_connect()
  assert_eq('db_connect_closes_previous', closes, 1)
  assert_eq('db_connect_replaces_handle', db_connection('default').id, 2)

  settings = saved_settings
  log_error = saved_log_error
  seawolf = saved_seawolf
  dbh = saved_dbh
  db_set_db_id = saved_db_set_db_id
  db_connect = saved_db_connect
  db_query = saved_db_query
  db_connection = saved_db_connection
  db_last_insert_id = saved_db_last_insert_id
  db_limit = saved_db_limit
  db_table_schema_sql = saved_db_table_schema_sql
  db_schema_cache_clear = saved_db_schema_cache_clear
  db_field = saved_db_field
  package.loaded.DBI = saved_dbi
  package.loaded['includes.database.sqlite3'] = saved_sqlite_driver
end

io.write(('\n%d passed, %d failed\n'):format(pass_count, fail_count))

os.exit(fail_count == 0 and 0 or 1)
