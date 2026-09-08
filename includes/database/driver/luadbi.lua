--[[ The three LuaDBI drivers, which differ only in what they are called.

  LuaDBI is synchronous: a query holds the whole worker until the server
  answers, so it cannot overlap requests and its throughput under concurrency
  lands on its serial figure or below it. Stage 8.3 measured PostgreSQL at
  9,843 serial and 6,784 concurrent.

  It stays for two reasons. SQLite has no socket and can never be non-blocking,
  so on the dev, CLI, test and low-scale path there is nothing to lose; and the
  `ophal` CLI runs under `lua5.1` with no cosockets, so a PostgreSQL site still
  needs a blocking driver for `ophal migrate apply`. That is the whole reason
  driver and dialect are separate keys.

  Each of the three has one correctness defect, and it is a different one per
  dialect. **postgresql and sqlite3 read integers with 32-bit precision** --
  5000000000 comes back as 705032704 from a real BIGINT column and from a bare
  literal alike, so the truncation is in LuaDBI's C on the way out and nothing
  above it can repair it. **mysql destroys NULL**, returning `''` where every
  call site expects nil. Writes are exact on all three. `tests/bench/`
  measures LuaSQL and lsqlite3 as free of both.
]]

local base = require 'includes.database.driver'

local M = {}

-- Closed either way, which is why the outcome is not a parameter here: LuaDBI
-- has no keepalive, and a handle kept across requests is the thing
-- `db_connect()` closes on purpose -- an unfinalized SQLite statement holds a
-- read transaction and blocks every later writer.
local function release(handle)
  pcall(function() handle:close() end)

  return false
end

--[[ LuaDBI returns a statement handle, not rows.

  `db_result.lua` is already the application's contract over exactly this
  shape -- `fetch`/`rows`/`close` -- so the driver hands the statement back
  unchanged and the connection wraps it. That contract was written in Phase 1
  for this driver, which is why it fits without adaptation.
]]
local function execute(handle, compiled, ...)
  local sth, err = handle:prepare(compiled.sql)

  if err or sth == nil then
    return nil, err or 'prepare failed'
  end

  local ok, execute_err = sth:execute(...)

  if execute_err then
    return nil, execute_err
  end

  return sth
end

--[[ SQLite's locking defaults, widened on every connection.

  SQLite permits many processes on one file, so multi-worker OpenResty is safe
  from corruption. It is not safe from lock contention, and the defaults make
  that contention loud: `busy_timeout` is 0, so a second writer fails at once
  with SQLITE_BUSY rather than waiting, and the rollback journal takes an
  exclusive lock that blocks readers too. Phase 3 made public reads into
  writers -- a moved projection version rebuilds from inside a GET -- so this is
  ordinary page traffic, not a corner.

  The timeout is deliberately short: LuaDBI is synchronous, so a worker waiting
  on a lock is a blocked worker rather than a yielded coroutine, and a long wait
  trades an error for a stall.

  This was `on_connect()` in `includes/database/sqlite3.lua`, which reached the
  database through the global `db_query()`. Here it runs on the handle it was
  given, before that handle is anybody's connection, so it needs no ambient
  state and cannot recurse into the layer.
]]
local DEFAULT_BUSY_TIMEOUT = 1000

--[[ Run one pragma and finalize it, returning the first column of its answer.

  Finalizing matters more than the answer does. Every pragma here returns a row
  -- `busy_timeout` echoes the timeout, `journal_mode` echoes the mode -- and a
  SQLite statement that has been executed but neither stepped to completion nor
  finalized holds a read transaction open on the connection. The old
  `db_connect()` said as much about handles kept across requests; the same rule
  applies to a statement kept across a pragma.

  Leaving one open here does not merely block later writers. It puts the
  connection inside an implicit transaction, so the next explicit `BEGIN` nests
  and the matching `ROLLBACK` unwinds everything the connection has done since
  it opened -- `tests/bench/driver_contract.lua` caught exactly that: a
  transaction test rolled back the CREATE TABLE that had set the contract up.
]]
local function pragma(handle, statement)
  local sth, err = handle:prepare(statement)
  local ok, row

  if sth ~= nil then
    ok, err = sth:execute()

    if ok then
      row = sth:fetch()
      sth:close()

      return row and row[1] or true
    end

    sth:close()
  end

  if type(log_error) == 'function' then
    log_error('sqlite pragma failed', {
      event = 'database_pragma_failed',
      error = err,
      query = statement,
    })
  end

  return nil
end

-- The mode the file is already in, or nil if it cannot be read. Journal mode is
-- a property of the file rather than of the connection, so a database switched
-- to WAL once comes back as WAL for every later connection.
local function current_journal_mode(handle)
  local mode = pragma(handle, 'PRAGMA journal_mode')

  return type(mode) == 'string' and mode:lower() or nil
end

local function sqlite_pragmas(handle, config)
  local timeout = tonumber(config.busy_timeout)
  local journal_mode = config.journal_mode

  -- `timeout ~= timeout` is the NaN test.
  if timeout == nil or timeout ~= timeout or timeout < 0 then
    timeout = DEFAULT_BUSY_TIMEOUT
  end

  pragma(handle, ('PRAGMA busy_timeout = %d'):format(math.floor(timeout)))

  -- WAL lets readers run while a writer holds the file, which is what stops a
  -- projection rebuild from failing concurrent page views. It needs shared
  -- memory and a local filesystem, so a site on a network filesystem sets
  -- `journal_mode = false` to stay in rollback mode.
  if journal_mode == false then
    return
  end

  if type(journal_mode) ~= 'string' or not journal_mode:match('^%a+$') then
    journal_mode = 'WAL'
  end

  -- Setting the mode takes an exclusive lock on the file, and takes it even
  -- when the requested mode is the one the file is already in. With a
  -- connection opened per request that turned every reader into a writer for
  -- the length of one pragma. Reading the mode first makes the common case --
  -- already WAL -- a shared-lock read that cannot collide.
  if current_journal_mode(handle) ~= journal_mode:lower() then
    pragma(handle, ('PRAGMA journal_mode = %s'):format(journal_mode))
  end
end

local ON_CONNECT = {sqlite3 = sqlite_pragmas}

local function connect(dbi_driver, dialect)
  return function(config)
    local DBI = require 'DBI'
    local hook = ON_CONNECT[dialect]
    local handle, err = DBI.Connect(
      dbi_driver,
      config.database,
      config.username,
      config.password,
      config.host,
      config.port
    )

    if not handle then
      return nil, err
    end

    -- Autocommit first, and that ordering is load-bearing. LuaDBI opens a
    -- transaction on connect, and SQLite refuses `PRAGMA journal_mode = WAL`
    -- from inside one with "cannot change into wal mode from within a
    -- transaction" -- which the pragma helper logs and continues past, leaving
    -- the file in rollback mode while reporting success.
    handle:autocommit(config.autocommit ~= false)

    if hook ~= nil then
      hook(handle, config)
    end

    return handle
  end
end

local LIMIT_CLAUSE = {
  postgresql = ' OFFSET ? LIMIT ?',
  sqlite3 = ' LIMIT ?, ?',
  mysql = ' LIMIT ?, ?',
}

function M.build(name, dialect, dbi_driver, quote)
  return {
    name = name,
    dialect = dialect,
    placeholder = 'question',
    quote_identifier = base.identifier_quoter(quote),
    limit_clause = LIMIT_CLAUSE[dialect],
    connect = connect(dbi_driver, dialect),
    execute = execute,
    release = release,
    -- LuaDBI's PostgreSQL and SQLite drivers leave a NULL column absent, which
    -- reads as nil. Its MySQL driver returns an empty string instead, which is
    -- `empty()` but is no longer distinguishable from a column that really
    -- holds one -- a defect this layer cannot repair, only record.
    rows = function(res) return res end,
  }
end

return M
