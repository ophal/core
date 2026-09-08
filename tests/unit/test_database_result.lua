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

-- Asserts that `fn` raises and that the message names `needle`, so a test
-- cannot pass on an error raised for some other reason.
local function assert_raises(label, needle, fn)
  local ok, err = pcall(fn)

  if ok then
    fail_count = fail_count + 1
    io.write(('  FAIL %s: expected an error naming %q, got none\n'):format(
      label, needle))
  elseif not tostring(err):find(needle, 1, true) then
    fail_count = fail_count + 1
    io.write(('  FAIL %s: expected an error naming %q, got: %s\n'):format(
      label, needle, tostring(err)))
  else
    pass_count = pass_count + 1
    io.write(('  ok %s\n'):format(label))
  end
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

do
  --[[ LuaDBI hands back **userdata**, not a table: its `fetch` is reached
    through a metatable. A wrapper that decided the shape by asking for a table
    would take every LuaDBI result for a list of rows and read nil from it,
    which is what `tests/bench/driver_contract.lua` caught on SQLite.
  ]]
  local handle = newproxy(true)
  local fake = new_fake_result()

  getmetatable(handle).__index = {
    fetch = function(_, named) return fake:fetch(named) end,
  }

  assert_eq('userdata_handle_pulls_rows',
    db_result.wrap(handle):fetch(true).name, 'alpha')
end

io.write '\n-- rows a driver built itself --\n'

--[[ The cosocket drivers do not hand back a statement handle to pull rows from.
  pgmoon and lua-resty-mysql both answer with the rows themselves, as a list of
  tables keyed by column name, so the wrapper reads a list as readily as a
  cursor. Without this the layer could not read a single row on either of the
  two drivers stage 8.3 chose -- and nothing caught it, because the bench
  measured `db:run()` without ever looking at what it returned.
]]
local function new_list_result()
  return {
    {id = 1, name = 'alpha'},
    {id = 2, name = 'beta'},
  }
end

do
  local wrapped = db_result.wrap(new_list_result())

  assert_eq('list_fetch_first', wrapped:fetch(true).name, 'alpha')
  assert_eq('list_fetch_advances', wrapped:fetch(true).name, 'beta')
  assert_eq('list_fetch_past_the_end', wrapped:fetch(true), nil)
end

do
  local wrapped = db_result.wrap(new_list_result())
  local names = {}

  for row in wrapped:rows(true) do
    names[#names + 1] = row.name
  end

  assert_eq('list_rows_count', #names, 2)
  assert_eq('list_rows_second', names[2], 'beta')
  assert_truthy('list_close_is_a_noop', wrapped:close())
end

do
  -- Handed over rather than copied: the front page and the tags menu both read
  -- a whole projection row set this way and then cache it, so a copy would be a
  -- second pass over every row to build a table indistinguishable from the one
  -- it discarded.
  local rows = new_list_result()
  local wrapped = db_result.wrap(rows)

  assert_eq('list_all_is_the_list_itself', wrapped:all(true), rows)
  -- And taken, so a second read does not serve the same rows again.
  assert_eq('list_all_consumes', #wrapped:all(true), 0)
end

do
  local wrapped = db_result.wrap(new_list_result())

  wrapped:fetch(true)

  assert_eq('list_all_after_a_fetch_skips_what_was_taken',
    #wrapped:all(true), 1)
end

do
  --[[ A hash row has no first column, and `lua-resty-mysql` has no other result
    mode to ask for -- so the layer takes rows by name on every backend rather
    than promising something two of its three drivers cannot keep. The refusal
    is what makes `(rs:fetch() or {})[1]` fail in the unit suite on SQLite
    instead of in production on PostgreSQL.
  ]]
  local list = db_result.wrap(new_list_result())
  local cursor = db_result.named(new_fake_result())

  assert_raises('list_refuses_a_positional_fetch', 'named',
    function() return list:fetch() end)
  assert_raises('layer_result_refuses_a_positional_fetch', 'named',
    function() return cursor:fetch() end)
  assert_raises('layer_result_refuses_positional_rows', 'named',
    function() return cursor:rows() end)
  assert_eq('layer_result_reads_by_name', cursor:fetch(true).name, 'alpha')

  -- The legacy `db_query()` path keeps positional rows: sixty-three call sites
  -- still read them that way, and LuaDBI can answer.
  assert_eq('wrap_still_reads_positionally',
    db_result.wrap(new_fake_result()):fetch()[2], 'alpha')
end

io.write '\n-- the database boundary --\n'

--[[ `includes/database/init.lua` is the whole application-facing surface now:
  one accessor answering with a connection object, and the transitional free
  functions that stage 8.5 deletes as the last call site leaves them.

  The DBI handle is mocked rather than a real database, because what is under
  test here is the boundary -- lazy connection, memoization per request,
  release -- and not what SQLite does with a statement.
]]
do
  local saved_settings = settings
  local saved_log_error = log_error
  local saved_dbi = package.loaded.DBI
  local config = require 'includes.database.config'
  local request_state = require 'includes.request_state'
  local connects, closes, prepared, calls = 0, 0, nil, {}

  package.loaded.DBI = {
    Connect = function()
      connects = connects + 1

      return {
        id = connects,
        autocommit = function()
          calls[#calls + 1] = 'autocommit'
        end,
        close = function()
          closes = closes + 1
          return true
        end,
        prepare = function(_, query)
          calls[#calls + 1] = query
          prepared = query

          return {
            execute = function() return true end,
            close = function() return true end,
            fetch = function(_, named)
              -- The journal-mode read is positional and below the layer; the
              -- application's own reads are named.
              if query == 'PRAGMA journal_mode' then
                return {'wal'}
              end

              return named and {value = 'wrapped'} or {'wrapped'}
            end,
          }
        end,
      }
    end,
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

  config.reset()
  request_state.reset()
  dofile('includes/database/init.lua')

  --[[ Nothing connects until a statement runs.

    Bootstrap phase 12 used to call `db_connect()` unconditionally, and the two
    queries a warm anonymous page cost were that connection's own SQLite
    pragmas. A page that reads everything from a projection cache now opens no
    socket at all, which is where those two went.
  ]]
  local db = db_connection()

  assert_eq('accessor_does_not_connect', connects, 0)
  assert_eq('accessor_memoizes_per_request', db_connection(), db)

  local rs = db_query('SELECT 1')

  assert_eq('query_connects_on_first_use', connects, 1)
  assert_eq('query_reaches_the_driver', prepared, 'SELECT 1')
  assert_eq('query_returns_a_wrapper', getmetatable(rs), db_result.Result)
  assert_eq('query_reads_by_name', rs:fetch(true).value, 'wrapped')

  -- LuaDBI opens a transaction on connect and SQLite refuses to change the
  -- journal mode from inside one, so the pragmas have to follow autocommit.
  -- Running them first lost WAL to a logged, non-fatal failure and left the
  -- file in rollback mode while reporting success.
  assert_eq('autocommit_precedes_the_pragmas', calls[1], 'autocommit')
  assert_eq('busy_timeout_is_set', calls[2], 'PRAGMA busy_timeout = 1000')

  -- Already WAL, so the mode is read and not set. Setting it takes an
  -- exclusive lock even when it would be a no-op, which turned every reader
  -- into a writer for the length of one pragma.
  assert_eq('journal_mode_is_read_first', calls[3], 'PRAGMA journal_mode')
  assert_eq('journal_mode_not_reset_when_current', calls[4], 'SELECT 1')

  local second = db_query('SELECT 2')

  assert_eq('second_query_reuses_the_connection', connects, 1)
  assert_truthy('second_query_answers', second)

  --[[ Release hands the socket back and marks the object.

    A connection kept in a module upvalue and used next request would otherwise
    reach a socket that request does not own -- the database-level form of the
    load-time capture class stage 8.2 closed for `_GET` and `_SESSION`.
  ]]
  assert_eq('release_all_releases_one', db_release_all(true), 1)
  assert_eq('release_closes_the_handle', closes, 1)
  assert_raises('released_connection_refuses_a_query', 'was released', function()
    db:run 'core.begin'
  end)

  -- And the accessor answers with a new object rather than the released one.
  assert_truthy('accessor_answers_again_after_release', db_connection() ~= db)

  settings = saved_settings
  log_error = saved_log_error
  package.loaded.DBI = saved_dbi
  config.reset()
  request_state.reset()
end

io.write(('\n%d passed, %d failed\n'):format(pass_count, fail_count))

os.exit(fail_count == 0 and 0 or 1)
