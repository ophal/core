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

local function record_queries()
  local queries = {}

  db_query = function(sql)
    queries[#queries + 1] = sql
    return {fetch = function() return {} end}
  end

  return queries
end

io.write '\n-- sqlite3 connection pragmas --\n'

-- A connection with no overrides gets both pragmas, in that order.
do
  local queries = record_queries()

  driver.on_connect({})

  assert_eq('sqlite_pragma_count', #queries, 2)
  assert_eq('sqlite_busy_timeout_default', queries[1], 'PRAGMA busy_timeout = 1000')
  assert_eq('sqlite_journal_mode_default', queries[2], 'PRAGMA journal_mode = WAL')
end

-- A missing connection table must not fault the connect path.
do
  local queries = record_queries()

  driver.on_connect(nil)

  assert_eq('sqlite_pragma_nil_connection', #queries, 2)
end

-- Settings override both values.
do
  local queries = record_queries()

  driver.on_connect({busy_timeout = 2500, journal_mode = 'TRUNCATE'})

  assert_eq('sqlite_busy_timeout_override', queries[1], 'PRAGMA busy_timeout = 2500')
  assert_eq('sqlite_journal_mode_override', queries[2], 'PRAGMA journal_mode = TRUNCATE')
end

-- A network filesystem cannot use WAL, so `false` leaves the journal alone.
do
  local queries = record_queries()

  driver.on_connect({journal_mode = false})

  assert_eq('sqlite_journal_mode_opt_out', #queries, 1)
  assert_eq('sqlite_journal_mode_opt_out_kept_timeout', queries[1], 'PRAGMA busy_timeout = 1000')
end

-- Pragmas take no bind parameters, so a value that reached SQL unvalidated
-- would be an injection point. Nonsense falls back to the default instead.
do
  local queries = record_queries()

  driver.on_connect({
    busy_timeout = 'plenty',
    journal_mode = 'WAL; DROP TABLE content',
  })

  assert_eq('sqlite_busy_timeout_invalid_defaults', queries[1], 'PRAGMA busy_timeout = 1000')
  assert_eq('sqlite_journal_mode_rejects_sql', queries[2], 'PRAGMA journal_mode = WAL')
end

-- Fractional and negative timeouts must still produce a valid integer pragma.
do
  local queries = record_queries()

  driver.on_connect({busy_timeout = 1500.9})
  assert_eq('sqlite_busy_timeout_floors', queries[1], 'PRAGMA busy_timeout = 1500')

  queries = record_queries()
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

io.write(('\n%d passed, %d failed\n'):format(pass_count, fail_count))
if fail_count > 0 then
  os.exit(1)
end
