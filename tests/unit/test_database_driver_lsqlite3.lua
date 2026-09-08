--[[ Unit tests for the lsqlite3 driver.

  The binding is a C module and is not installed everywhere this suite runs, so
  `lsqlite3` is stubbed here and the real thing is exercised against a real
  database by `tests/bench/driver_contract.lua`. What is under test is what the
  driver does with the binding: the connection pragmas, the prepared-statement
  cache, and the resetting and finalizing that decide whether a connection is
  left inside an implicit transaction.
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

local ROW, DONE = 100, 101

--[[ A stand-in for the binding.

  `state.rows[sql]` scripts what a statement answers; anything unscripted
  answers no rows. Every prepare, reset and finalize is counted, because those
  counts are the behaviour worth pinning.
]]
local function new_state()
  return {
    prepared = {},
    statements = {},
    resets = 0,
    finalized = 0,
    rows = {},
    journal_mode = 'delete',
  }
end

local function install(state)
  local sqlite3 = {ROW = ROW, DONE = DONE, OK = 0}

  -- `PRAGMA journal_mode` answers one row, which is what makes the read a read.
  -- Its value comes from `get_value`, so the row itself carries nothing.
  state.rows['PRAGMA journal_mode'] = {{}}

  function sqlite3.open(path)
    local db = {}

    state.opened = path

    function db:busy_timeout(ms)
      state.busy_timeout = ms
    end

    function db:errmsg()
      return state.errmsg or 'stubbed failure'
    end

    function db:close()
      state.closed = true
      return 0
    end

    function db:prepare(sql)
      local stmt = {sql = sql, cursor = 0}

      state.prepared[#state.prepared + 1] = sql

      if state.prepare_fails and sql:find(state.prepare_fails, 1, true) then
        return nil
      end

      state.statements[#state.statements + 1] = stmt

      function stmt:bind_values(...)
        state.bound = {...}
        state.bound_count = select('#', ...)
        return 0
      end

      function stmt:step()
        if state.step_fails and sql:find(state.step_fails, 1, true) then
          return 5
        end

        local rows = state.rows[sql] or {}

        self.cursor = self.cursor + 1

        return self.cursor <= #rows and ROW or DONE
      end

      function stmt:get_named_values()
        return (state.rows[sql] or {})[self.cursor]
      end

      -- Only the journal-mode read uses this, and it reads column zero.
      function stmt:get_value()
        return state.journal_mode
      end

      function stmt:reset()
        self.cursor = 0
        state.resets = state.resets + 1
        return 0
      end

      function stmt:finalize()
        self.finalized = true
        state.finalized = state.finalized + 1
        return 0
      end

      return stmt
    end

    return db
  end

  package.loaded.lsqlite3 = sqlite3

  return require 'includes.database.driver.lsqlite3'
end

local function connect(config, state)
  local driver = install(state)

  return driver, driver.connect(config or {database = ':memory:'})
end

io.write '\n-- lsqlite3 connection pragmas --\n'

do
  local state = new_state()
  local _, handle = connect({database = 'site.sqlite'}, state)

  assert_eq('lsqlite_opens_the_configured_file', state.opened, 'site.sqlite')
  assert_eq('lsqlite_handle_carries_the_database', handle.db ~= nil, true)
  assert_eq('lsqlite_handle_carries_a_statement_cache',
    type(handle.statements), 'table')

  -- Native, so the timeout is not a statement and cannot be left open. That
  -- alone removes the failure mode the LuaDBI driver had to be taught.
  assert_eq('lsqlite_busy_timeout_default', state.busy_timeout, 1000)

  -- The file is in rollback mode, so the mode is read and then written.
  assert_eq('lsqlite_journal_mode_read', state.prepared[1], 'PRAGMA journal_mode')
  assert_eq('lsqlite_journal_mode_written', state.prepared[2],
    'PRAGMA journal_mode = WAL')
  assert_eq('lsqlite_pragma_count', #state.prepared, 2)
end

-- Setting the mode takes an exclusive lock even when it would be a no-op, so a
-- file already in WAL is left alone.
do
  local state = new_state()

  state.journal_mode = 'wal'
  connect(nil, state)

  assert_eq('lsqlite_journal_mode_already_set', #state.prepared, 1)
  assert_eq('lsqlite_journal_mode_only_read', state.prepared[1],
    'PRAGMA journal_mode')
end

do
  local state = new_state()

  connect({database = ':memory:', busy_timeout = 2500,
    journal_mode = 'TRUNCATE'}, state)

  assert_eq('lsqlite_busy_timeout_override', state.busy_timeout, 2500)
  assert_eq('lsqlite_journal_mode_override', state.prepared[2],
    'PRAGMA journal_mode = TRUNCATE')
end

-- WAL needs shared memory and a local filesystem, so a site on a network
-- filesystem opts out. The timeout still applies.
do
  local state = new_state()

  connect({database = ':memory:', journal_mode = false}, state)

  assert_eq('lsqlite_journal_mode_opt_out', #state.prepared, 0)
  assert_eq('lsqlite_journal_mode_opt_out_keeps_timeout', state.busy_timeout, 1000)
end

-- A journal mode that is not a bare word is settings-borne SQL on its way into
-- an interpolated pragma, so it is refused rather than sent.
do
  local state = new_state()

  connect({database = ':memory:', busy_timeout = 'soon',
    journal_mode = 'WAL; DROP TABLE users'}, state)

  assert_eq('lsqlite_busy_timeout_invalid_defaults', state.busy_timeout, 1000)
  assert_eq('lsqlite_journal_mode_rejects_sql', state.prepared[2],
    'PRAGMA journal_mode = WAL')
end

do
  local state = new_state()

  connect({database = ':memory:', busy_timeout = 1500.7}, state)
  assert_eq('lsqlite_busy_timeout_floors', state.busy_timeout, 1500)

  state = new_state()
  connect({database = ':memory:', busy_timeout = -5}, state)
  assert_eq('lsqlite_busy_timeout_negative_defaults', state.busy_timeout, 1000)
end

-- Both pragma statements are finalized. A statement that has been executed but
-- neither stepped to completion nor finalized holds a read transaction open,
-- which puts the connection inside an implicit transaction -- so the next
-- explicit BEGIN nests and its ROLLBACK unwinds everything since connect.
do
  local state = new_state()

  connect(nil, state)

  assert_eq('lsqlite_pragmas_are_finalized', state.finalized, #state.statements)
end

io.write '\n-- lsqlite3 statements --\n'

do
  local state = new_state()
  local driver, handle = connect(nil, state)
  local before = #state.prepared
  local sql = 'SELECT id, name FROM t WHERE id = ?'
  local rows

  state.rows[sql] = {{id = 1, name = 'alpha'}}

  rows = driver.execute(handle, {sql = sql, nparams = 1}, 1)

  assert_eq('lsqlite_execute_returns_a_list', #rows, 1)
  assert_eq('lsqlite_row_is_named', rows[1].name, 'alpha')
  assert_eq('lsqlite_binds_its_parameters', state.bound_count, 1)
  assert_eq('lsqlite_rows_is_the_list_itself', driver.rows(rows), rows)

  -- Reset rather than finalized, which is what leaves the connection outside a
  -- transaction *and* lets the next call skip the parse.
  assert_eq('lsqlite_statement_is_reset', state.resets, 1)

  driver.execute(handle, {sql = sql, nparams = 1}, 2)

  assert_eq('lsqlite_statement_is_prepared_once',
    #state.prepared - before, 1)
  assert_eq('lsqlite_statement_is_reset_each_time', state.resets, 2)

  -- A different statement is its own entry.
  state.rows['SELECT 1'] = {}
  driver.execute(handle, {sql = 'SELECT 1', nparams = 0}, nil)
  assert_eq('lsqlite_second_statement_is_prepared',
    #state.prepared - before, 2)
  assert_eq('lsqlite_no_bind_without_parameters', state.bound_count, 1)
end

-- A statement that produced no rows produced an empty list, never nil and never
-- a boolean: `includes/database/result.lua` reads it as a list either way.
do
  local state = new_state()
  local driver, handle = connect(nil, state)
  local rows = driver.execute(handle, {sql = 'DELETE FROM t', nparams = 0})

  assert_eq('lsqlite_no_rows_is_an_empty_list', #rows, 0)
  assert_eq('lsqlite_no_rows_is_a_table', type(rows), 'table')
end

do
  local state = new_state()
  local driver, handle = connect(nil, state)
  local rows, err

  state.prepare_fails = 'FROM missing'
  state.errmsg = 'no such table: missing'

  rows, err = driver.execute(handle, {sql = 'SELECT * FROM missing', nparams = 0})

  assert_eq('lsqlite_prepare_failure_returns_nil', rows, nil)
  assert_eq('lsqlite_prepare_failure_names_the_table', err,
    'no such table: missing')
end

-- A step that ends on anything but DONE -- SQLITE_BUSY, most often -- is an
-- error, and the statement is reset before it is reported so nothing is left
-- holding a read transaction.
do
  local state = new_state()
  local driver, handle = connect(nil, state)
  local before = state.resets
  local rows, err

  state.step_fails = 'FROM locked'
  state.errmsg = 'database is locked'

  rows, err = driver.execute(handle, {sql = 'SELECT * FROM locked', nparams = 0})

  assert_eq('lsqlite_step_failure_returns_nil', rows, nil)
  assert_eq('lsqlite_step_failure_reports_the_message', err, 'database is locked')
  assert_eq('lsqlite_step_failure_still_resets', state.resets, before + 1)
end

io.write '\n-- lsqlite3 release --\n'

-- SQLite refuses to close a connection that still has an open statement, and a
-- statement outliving its database is the same bug in the other direction.
do
  local state = new_state()
  local driver, handle = connect(nil, state)
  local before = state.finalized

  state.rows['SELECT 1'] = {}
  driver.execute(handle, {sql = 'SELECT 1', nparams = 0})
  driver.execute(handle, {sql = 'SELECT 2', nparams = 0})

  assert_eq('lsqlite_release_reports_no_pool', driver.release(handle, true), false)
  assert_eq('lsqlite_release_finalizes_every_statement',
    state.finalized - before, 2)
  assert_eq('lsqlite_release_empties_the_cache',
    next(handle.statements), nil)
  assert_eq('lsqlite_release_closes_the_database', state.closed, true)
end

io.write(('\n%d passed, %d failed\n'):format(pass_count, fail_count))
if fail_count > 0 then
  os.exit(1)
end
