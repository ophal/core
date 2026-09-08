--[[ SQLite over lsqlite3.

  Chosen over LuaDBI on correctness first. **LuaDBI reads integer columns with
  32-bit precision** -- 5000000000 comes back as 705032704, from a real column
  and from a bare literal alike -- so the truncation is in its C on the way out
  and nothing above it can repair it. Unix seconds cross 2^31 in January 2038
  and a file over 2 GB reaches it today. lsqlite3 reads the same value exactly;
  `tests/bench/driver_contract.lua` asserts both, side by side.

  Speed is the second reason and a smaller one than the bench headline suggests.
  Stage 8.3 measured 142,857 point selects a second against LuaDBI's 75,758, but
  that was 5,000 operations down one connection. Ophal's connections live one
  request and issue a handful of statements, so what the cache actually buys is
  reuse *within* a request -- and the place that matters is a projection rebuild,
  which runs one INSERT N times. Writes are fsync-bound at about a thousand a
  second on every binding, so none of this touches them.

  SQLite has no socket and can never be non-blocking, whatever the binding. This
  is the dev, CLI, test and low-scale path, and it stays that way.
]]

local base = require 'includes.database.driver'

local M = {
  name = 'lsqlite3',
  dialect = 'sqlite3',
  placeholder = 'question',
  quote_identifier = base.identifier_quoter '"',
  limit_clause = ' LIMIT ?, ?',
}

-- Widened from SQLite's own default of 0, which fails a second writer
-- immediately with SQLITE_BUSY rather than waiting. Phase 3 made public reads
-- into writers -- a stale projection rebuilds from inside a GET -- so several
-- workers writing at once is ordinary page traffic. The wait stays short
-- because SQLite is synchronous: a worker waiting on a lock is a blocked
-- worker, and a long wait trades an error for a stall.
local DEFAULT_BUSY_TIMEOUT = 1000

-- lsqlite3's step results, read off the library the first time a connection is
-- made. The library is required inside `connect()` rather than at load, the way
-- every other driver requires its own, so that this module can be loaded to
-- compile statements for the sqlite3 dialect on a host that has no binding.
local ROW, DONE

--[[ Read one pragma, stepping it to completion.

  Every pragma answers a row, and a SQLite statement that has been executed but
  neither stepped to completion nor finalized holds a read transaction open --
  which puts the connection inside an implicit transaction, so the next explicit
  `BEGIN` nests and its `ROLLBACK` unwinds everything since connect. That is not
  hypothetical: it is what `includes/database/driver/luadbi.lua` was doing until
  `tests/bench/driver_contract.lua` caught it.
]]
local function read_pragma(db, statement)
  local stmt = db:prepare(statement)
  local value

  if stmt == nil then
    return nil
  end

  if stmt:step() == ROW then
    value = stmt:get_value(0)
  end

  stmt:finalize()

  return value
end

local function apply_pragmas(db, config)
  local timeout = tonumber(config.busy_timeout)
  local journal_mode = config.journal_mode
  local current

  -- `timeout ~= timeout` is the NaN test.
  if timeout == nil or timeout ~= timeout or timeout < 0 then
    timeout = DEFAULT_BUSY_TIMEOUT
  end

  -- Native, so this one is not a statement at all and cannot be left open.
  db:busy_timeout(math.floor(timeout))

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

  -- Setting the mode takes an exclusive lock on the file even when it is
  -- already the mode in force, so a connection opened per request would turn
  -- every reader into a writer for the length of one pragma. Journal mode is a
  -- property of the file rather than of the connection, so reading it first
  -- makes the common case a shared-lock read that cannot collide.
  current = read_pragma(db, 'PRAGMA journal_mode')

  if type(current) == 'string' and current:lower() == journal_mode:lower() then
    return
  end

  read_pragma(db, ('PRAGMA journal_mode = %s'):format(journal_mode))
end

--[[ The handle is a table, not the database userdata.

  A prepared statement belongs to one connection, so the cache that holds them
  has to live beside that connection -- and userdata takes no fields. The layer
  treats a handle as opaque between `connect` and `release`, so wrapping it is
  free; `Connection:handle()` hands this table to the migration and installer
  paths, which reach `.db` for anything lsqlite3-specific.
]]
--[[ What to say when the binding is not installed.

  Ophal is experimental and the SQLite swap is allowed to break an upgrade, but
  it has to break it legibly. Without this the failure is
  `module 'lsqlite3' not found` followed by a page of search paths, raised from
  inside the first query rather than from the thing that changed.

  LuaDBI being present is what an upgrading site looks like, so it is worth
  saying out loud: it is not that the install is broken, it is that SQLite moved.
]]
local function missing_binding()
  local message = 'the lsqlite3 binding is not installed'

  if package.loaded.DBI ~= nil or pcall(require, 'DBI') then
    message = message .. ', and LuaDBI is\n'
      .. 'installed but is no longer what Ophal uses for SQLite'
  end

  return message .. '.\n'
    .. 'LuaDBI reads integer columns with 32-bit precision, so a timestamp\n'
    .. 'breaks in January 2038 and a file over 2 GB reads wrong today.\n'
    .. '  luarocks install lsqlite3complete\n'
    .. 'More: https://github.com/ophal/core'
end

function M.connect(config)
  local loaded, sqlite3 = pcall(require, 'lsqlite3')
  local db, code, message

  if not loaded then
    return nil, missing_binding()
  end

  db, code, message = sqlite3.open(config.database)

  ROW, DONE = sqlite3.ROW, sqlite3.DONE

  if db == nil then
    return nil, message or ('lsqlite3 could not open %q (%s)'):format(
      tostring(config.database), tostring(code))
  end

  -- No autocommit call, and none is wanted. SQLite is in autocommit until a
  -- statement opens a transaction, so `config.autocommit` means nothing here --
  -- unlike LuaDBI, which opens one on connect and has to be told not to.
  apply_pragmas(db, config)

  return {db = db, statements = {}}
end

--[[ The prepared statement for a compiled one, made once per connection.

  Keyed on the SQL rather than on the statement name because ad-hoc text reaches
  here too, and because a statement with identifiers compiles to different SQL
  per identifier value. The cache dies with the connection, which is one
  request.
]]
local function prepared(handle, sql)
  local stmt = handle.statements[sql]

  if stmt == nil then
    stmt = handle.db:prepare(sql)

    if stmt == nil then
      return nil, handle.db:errmsg()
    end

    handle.statements[sql] = stmt
  end

  return stmt
end

--[[ Run a statement and read every row it has.

  Eager, and deliberately so. A statement left mid-scan holds a read
  transaction, and this driver's whole reason for existing is that the previous
  one got that wrong; stepping to completion and resetting leaves the connection
  in a state where the next `BEGIN` means what it says. Ophal's reads are point
  lookups, paginated pages and rebuild scans that the caller consumes whole
  anyway, so nothing here streams.

  The statement is reset rather than finalized, which is what lets the next call
  with the same SQL skip the parse.
]]
function M.execute(handle, compiled, ...)
  local stmt, err = prepared(handle, compiled.sql)
  local rows, code

  if stmt == nil then
    return nil, err
  end

  if compiled.nparams > 0 then
    stmt:bind_values(...)
  end

  rows = {}
  code = stmt:step()

  while code == ROW do
    -- Absent for a SQL NULL, which is nil in Lua and what every call site
    -- already assumes. No normalising pass is needed here, unlike the two
    -- cosocket drivers.
    rows[#rows + 1] = stmt:get_named_values()
    code = stmt:step()
  end

  stmt:reset()

  if code ~= DONE then
    return nil, handle.db:errmsg()
  end

  return rows
end

-- Already the shape `includes/database/result.lua` calls a list.
function M.rows(res)
  return res
end

--[[ Give the file up.

  Every cached statement is finalized first: SQLite refuses to close a
  connection that still has one open, and a statement outliving its database is
  the same class of bug in the other direction. There is no pool to return to --
  SQLite has no socket -- so `ok` decides nothing here.
]]
function M.release(handle, _)
  for sql, stmt in pairs(handle.statements) do
    pcall(function() stmt:finalize() end)
    handle.statements[sql] = nil
  end

  pcall(function() handle.db:close() end)

  return false
end

return M
