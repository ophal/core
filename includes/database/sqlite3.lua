local _M = {}

-- SQLite permits many processes on one database file, so a multi-worker
-- OpenResty deployment is safe from corruption. It is not safe from lock
-- contention, and the defaults make that contention loud: `busy_timeout` is 0,
-- so a second writer fails immediately with SQLITE_BUSY rather than waiting,
-- and the rollback journal takes an exclusive lock that blocks readers too.
--
-- Public reads became writers in Phase 3. A moved projection version makes
-- `projection.ensure()` rebuild from inside a GET, so several workers can write
-- the same projection at once on ordinary page traffic. These pragmas are what
-- keep that from surfacing as 500s on unrelated page views.
--
-- The timeout is deliberately short. LuaDBI is synchronous, so a worker waiting
-- on a lock is a blocked worker rather than a yielded coroutine; a long wait
-- trades an error for a stall, which is worse under load.
local DEFAULT_BUSY_TIMEOUT = 1000

local function pragma(statement)
  local ok, err = pcall(db_query, statement)

  if not ok and type(log_error) == 'function' then
    log_error('sqlite pragma failed', {
      event = 'database_pragma_failed',
      error = err,
      query = statement,
    })
  end

  return ok
end

-- Called once per connection, after the handle exists. Pragmas take no bind
-- parameters, so both values are interpolated; both are validated here rather
-- than passed through from settings as written.
function _M.on_connect(connection)
  local timeout = tonumber((connection or {}).busy_timeout)
  local journal_mode = (connection or {}).journal_mode

  -- `timeout ~= timeout` is the NaN test.
  if timeout == nil or timeout ~= timeout or timeout < 0 then
    timeout = DEFAULT_BUSY_TIMEOUT
  end

  pragma(('PRAGMA busy_timeout = %d'):format(math.floor(timeout)))

  -- WAL lets readers run while a writer holds the file, which is what stops a
  -- projection rebuild from failing concurrent page views. It needs shared
  -- memory and a local filesystem, so a site on a network filesystem can set
  -- `journal_mode = false` to leave the database in rollback mode.
  if journal_mode ~= false then
    if type(journal_mode) ~= 'string' or not journal_mode:match('^%a+$') then
      journal_mode = 'WAL'
    end

    pragma(('PRAGMA journal_mode = %s'):format(journal_mode))
  end
end

function _M.last_insert_id(tbl_name)
  local sth, err, row

  sth, err = db_query('SELECT last_insert_rowid()')
  if err then
    return nil, err
  else
    row = sth:fetch()
    return row[1]
  end
end

function _M.limit()
  return ' LIMIT ?, ?'
end

return _M
