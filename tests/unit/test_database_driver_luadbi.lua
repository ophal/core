--[[ Unit tests for the LuaDBI driver's connection-time pragmas.

  Multi-worker OpenResty means several processes write one database file, and
  Phase 3 made public reads capable of writing (a stale projection rebuilds
  from inside a GET). The stock SQLite defaults answer that with an immediate
  SQLITE_BUSY and a journal that blocks readers, so these pragmas are load
  bearing rather than cosmetic.

  They were `on_connect()` in `includes/database/sqlite3.lua`, which reached the
  database through the global `db_query()`. Stage 8.5 moved them onto the handle
  the driver has just opened, before it is anybody's connection, so what is
  driven here is `driver.connect()` itself.
]]

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

--[[ A DBI stand-in that records the statements a connection prepares.

  `current_mode` is what `PRAGMA journal_mode` reports back -- the mode the
  database file is already in. nil stands for a read that returned nothing.
]]
local function record_queries(current_mode, failing)
  local queries = {}

  package.loaded.DBI = {
    Connect = function()
      return {
        autocommit = function() end,
        prepare = function(_, sql)
          queries[#queries + 1] = sql

          if failing then
            return nil, 'no such pragma'
          end

          return {
            execute = function() return true end,
            close = function() return true end,
            fetch = function()
              if sql == 'PRAGMA journal_mode' then
                return {current_mode}
              end

              return {}
            end,
          }
        end,
      }
    end,
  }

  return queries
end

local function connect(config, current_mode, failing)
  local queries = record_queries(current_mode, failing)
  -- Required after the stand-in is in place: the driver reaches for DBI inside
  -- `connect`, so the module itself carries no reference to hold stale.
  local driver = require 'includes.database.driver.luadbi_sqlite3'

  return queries, driver.connect(config)
end

io.write '\n-- sqlite3 connection pragmas --\n'

-- A connection with no overrides sets the timeout, reads the journal mode, and
-- sets it because the file is not in it yet.
do
  local queries = connect({}, 'delete')

  assert_eq('sqlite_pragma_count', #queries, 3)
  assert_eq('sqlite_busy_timeout_default', queries[1], 'PRAGMA busy_timeout = 1000')
  assert_eq('sqlite_journal_mode_read', queries[2], 'PRAGMA journal_mode')
  assert_eq('sqlite_journal_mode_default', queries[3], 'PRAGMA journal_mode = WAL')
end

-- Setting the journal mode takes an exclusive lock even when it is already the
-- mode in force, which fails under any concurrent reader. A file already in WAL
-- must therefore be left alone -- and that is the common case, since journal
-- mode is a property of the file rather than of the connection.
do
  local queries = connect({}, 'wal')

  assert_eq('sqlite_journal_mode_already_set_count', #queries, 2)
  assert_eq('sqlite_journal_mode_already_set_read', queries[2], 'PRAGMA journal_mode')
end

-- SQLite reports the mode in lower case and the pragma is written in upper.
do
  local queries = connect({}, 'WAL')

  assert_eq('sqlite_journal_mode_case_insensitive', #queries, 2)
end

-- A read that answers nothing is not "already in the mode": it is unknown, and
-- the pragma is written rather than skipped.
do
  local queries = connect({}, nil)

  assert_eq('sqlite_journal_mode_unknown_still_set', #queries, 3)
  assert_eq('sqlite_journal_mode_unknown_writes', queries[3], 'PRAGMA journal_mode = WAL')
end

-- Both values are interpolated, so both are validated here rather than passed
-- through from settings as written.
do
  local queries = connect({busy_timeout = 2500, journal_mode = 'TRUNCATE'}, 'delete')

  assert_eq('sqlite_busy_timeout_override', queries[1], 'PRAGMA busy_timeout = 2500')
  assert_eq('sqlite_journal_mode_override', queries[3], 'PRAGMA journal_mode = TRUNCATE')
end

-- WAL needs shared memory and a local filesystem, so a site on a network
-- filesystem opts out and stays in rollback mode. The timeout still applies.
do
  local queries = connect({journal_mode = false}, 'delete')

  assert_eq('sqlite_journal_mode_opt_out', #queries, 1)
  assert_eq('sqlite_journal_mode_opt_out_kept_timeout', queries[1],
    'PRAGMA busy_timeout = 1000')
end

-- A journal mode that is not a bare word is settings-borne SQL on its way into
-- an interpolated statement, so it is refused rather than sent.
do
  local queries = connect(
    {busy_timeout = 'soon', journal_mode = 'WAL; DROP TABLE users'}, 'delete')

  assert_eq('sqlite_busy_timeout_invalid_defaults', queries[1],
    'PRAGMA busy_timeout = 1000')
  assert_eq('sqlite_journal_mode_rejects_sql', queries[3], 'PRAGMA journal_mode = WAL')
end

do
  local queries = connect({busy_timeout = 1500.7}, 'wal')

  assert_eq('sqlite_busy_timeout_floors', queries[1], 'PRAGMA busy_timeout = 1500')
end

do
  local queries = connect({busy_timeout = -5}, 'wal')

  assert_eq('sqlite_busy_timeout_negative_defaults', queries[1],
    'PRAGMA busy_timeout = 1000')
end

-- A pragma that fails must not take the connection down with it. The handle is
-- usable; the database is merely in a less forgiving locking mode than asked
-- for, which is worth a log line and not a 500.
do
  local logged
  local saved_log_error = log_error

  log_error = function(message) logged = message end

  local ok, _, handle = pcall(connect, {}, 'delete', true)

  assert_eq('sqlite_pragma_failure_survives', ok, true)
  assert_eq('sqlite_pragma_failure_returns_handle', handle ~= nil, true)
  assert_eq('sqlite_pragma_failure_logged', logged, 'sqlite pragma failed')

  log_error = saved_log_error
end

-- Only SQLite has a hook. A PostgreSQL or MySQL connection through LuaDBI
-- prepares nothing before the caller's first statement.
do
  local queries = record_queries('delete')
  local driver = require 'includes.database.driver.luadbi_postgresql'

  driver.connect{database = 'ophal'}

  assert_eq('no_pragmas_on_postgresql', #queries, 0)
end

io.write(('\n%d passed, %d failed\n'):format(pass_count, fail_count))
if fail_count > 0 then
  os.exit(1)
end
