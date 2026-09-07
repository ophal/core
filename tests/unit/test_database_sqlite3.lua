-- Unit tests for sqlite3 connection pragmas.
--
-- Multi-worker OpenResty means several processes write one database file, and
-- Phase 3 made public reads capable of writing (a stale projection rebuilds
-- from inside a GET). The stock SQLite defaults answer that with an immediate
-- SQLITE_BUSY and a journal that blocks readers, so the pragmas below are load
-- bearing rather than cosmetic.

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

local driver = dofile('includes/database/sqlite3.lua')

-- `current_mode` is what `PRAGMA journal_mode` reports back, i.e. the mode the
-- database file is already in. nil stands for a read that returned nothing.
local function record_queries(current_mode)
  local queries = {}

  db_query = function(sql)
    queries[#queries + 1] = sql

    if sql == 'PRAGMA journal_mode' then
      return {fetch = function() return {current_mode} end}
    end

    return {fetch = function() return {} end}
  end

  return queries
end

io.write '\n-- sqlite3 connection pragmas --\n'

-- A connection with no overrides sets the timeout, reads the journal mode, and
-- sets it because the file is not in it yet.
do
  local queries = record_queries('delete')

  driver.on_connect({})

  assert_eq('sqlite_pragma_count', #queries, 3)
  assert_eq('sqlite_busy_timeout_default', queries[1], 'PRAGMA busy_timeout = 1000')
  assert_eq('sqlite_journal_mode_read', queries[2], 'PRAGMA journal_mode')
  assert_eq('sqlite_journal_mode_default', queries[3], 'PRAGMA journal_mode = WAL')
end

-- Setting the journal mode takes an exclusive lock even when it is already the
-- mode in force, which fails under any concurrent reader. A file already in WAL
-- must therefore be left alone -- this is the common case, since journal mode
-- is a property of the file and bootstrap opens a connection per request.
do
  local queries = record_queries('wal')

  driver.on_connect({})

  assert_eq('sqlite_journal_mode_already_set_count', #queries, 2)
  assert_eq('sqlite_journal_mode_already_set_read', queries[2], 'PRAGMA journal_mode')
end

-- The comparison is case insensitive: SQLite reports the mode in lower case
-- whatever case it was set in.
do
  local queries = record_queries('WAL')

  driver.on_connect({journal_mode = 'wal'})

  assert_eq('sqlite_journal_mode_case_insensitive', #queries, 2)
end

-- A read that reports nothing must not stop the pragma from being written;
-- leaving the journal unset is the worse failure.
do
  local queries = record_queries(nil)

  driver.on_connect({})

  assert_eq('sqlite_journal_mode_unknown_still_set', #queries, 3)
  assert_eq('sqlite_journal_mode_unknown_writes', queries[3], 'PRAGMA journal_mode = WAL')
end

-- A missing connection table must not fault the connect path.
do
  local queries = record_queries('delete')

  driver.on_connect(nil)

  assert_eq('sqlite_pragma_nil_connection', #queries, 3)
end

-- Settings override both values.
do
  local queries = record_queries('wal')

  driver.on_connect({busy_timeout = 2500, journal_mode = 'TRUNCATE'})

  assert_eq('sqlite_busy_timeout_override', queries[1], 'PRAGMA busy_timeout = 2500')
  assert_eq('sqlite_journal_mode_override', queries[3], 'PRAGMA journal_mode = TRUNCATE')
end

-- A network filesystem cannot use WAL, so `false` leaves the journal alone.
do
  local queries = record_queries('delete')

  driver.on_connect({journal_mode = false})

  assert_eq('sqlite_journal_mode_opt_out', #queries, 1)
  assert_eq('sqlite_journal_mode_opt_out_kept_timeout', queries[1], 'PRAGMA busy_timeout = 1000')
end

-- Pragmas take no bind parameters, so a value that reached SQL unvalidated
-- would be an injection point. Nonsense falls back to the default instead.
do
  local queries = record_queries('delete')

  driver.on_connect({
    busy_timeout = 'plenty',
    journal_mode = 'WAL; DROP TABLE content',
  })

  assert_eq('sqlite_busy_timeout_invalid_defaults', queries[1], 'PRAGMA busy_timeout = 1000')
  assert_eq('sqlite_journal_mode_rejects_sql', queries[3], 'PRAGMA journal_mode = WAL')
end

-- Fractional and negative timeouts must still produce a valid integer pragma.
do
  local queries = record_queries('wal')

  driver.on_connect({busy_timeout = 1500.9})
  assert_eq('sqlite_busy_timeout_floors', queries[1], 'PRAGMA busy_timeout = 1500')

  queries = record_queries('wal')
  driver.on_connect({busy_timeout = -5})
  assert_eq('sqlite_busy_timeout_negative_defaults', queries[1], 'PRAGMA busy_timeout = 1000')
end

-- A driver that fails a pragma must not take the connection down with it.
do
  local logged

  db_query = function() error('no such pragma') end
  log_error = function(message) logged = message end

  local ok = pcall(driver.on_connect, {})

  assert_eq('sqlite_pragma_failure_survives', ok, true)
  assert_eq('sqlite_pragma_failure_logged', logged, 'sqlite pragma failed')

  log_error = nil
end

io.write '\n-- sqlite3 schema introspection --\n'

-- `db_field()` needs a statement that lists a table's columns as `field_name`,
-- and the driver had none, so loading a user or a file by field raised
-- "attempt to call field 'table_schema_sql'" on every SQLite site.
do
  local sql = driver.table_schema_sql()

  assert_eq('sqlite_schema_sql_is_string', type(sql), 'string')
  assert_eq('sqlite_schema_sql_aliases_field_name', sql:match('field_name') ~= nil, true)
  -- The table name arrives as a bind parameter; `PRAGMA table_info` takes none,
  -- which is why the table-valued form is used.
  assert_eq('sqlite_schema_sql_binds_table', sql:match('%?') ~= nil, true)
  assert_eq('sqlite_schema_sql_uses_pragma_function', sql:match('pragma_table_info') ~= nil, true)
end

io.write(('\n%d passed, %d failed\n'):format(pass_count, fail_count))
if fail_count > 0 then
  os.exit(1)
end
