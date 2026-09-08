--[[ The three LuaDBI drivers, which differ only in what they are called.

  LuaDBI is synchronous: a query holds the whole worker until the server
  answers, so it cannot overlap requests and its throughput under concurrency
  lands on its serial figure or below it. Stage 8.3 measured PostgreSQL at
  9,843 serial and 6,784 concurrent.

  It stays for one reason: the `ophal` CLI runs under `lua5.1` with no
  cosockets, so a PostgreSQL or MySQL site still needs a blocking driver for
  `ophal migrate apply`. That is the whole reason driver and dialect are
  separate keys -- the same statements reach one database through pgmoon in the
  worker and through LuaDBI on the command line.

  It no longer serves SQLite. **LuaDBI reads integer columns with 32-bit
  precision** -- 5000000000 comes back as 705032704, from a real BIGINT column
  and from a bare literal alike, so the truncation is in its C on the way out
  and nothing above it can repair it. `driver/lsqlite3.lua` replaced it on
  2026-09-08.

  The defect is still here on `postgresql`, and `mysql` has its own: it returns
  `''` for a SQL NULL, indistinguishable from a column that holds one. Both are
  confined to the CLI now, where migrations read no nullable column and no
  value near 2^31. Retiring them means a blocking PostgreSQL driver the CLI can
  use -- pgmoon under `socket_type = 'luasocket'` is the candidate and stage 8.6
  is where it can be verified against a real server's authentication.
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

local function connect(dbi_driver)
  return function(config)
    local DBI = require 'DBI'
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

    -- LuaDBI opens a transaction on connect, so this is not optional: without
    -- it the first explicit `BEGIN` nests and its `ROLLBACK` unwinds everything
    -- the connection has done.
    handle:autocommit(config.autocommit ~= false)

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
    connect = connect(dbi_driver),
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
