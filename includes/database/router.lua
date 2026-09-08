--[[ The accessor, and the request's connection lifetime.

  `db_connection(name)` is the Phase 1 name and keeps it. It answers with a
  connection object rather than a raw DBI handle, and it memoizes per identifier
  per request, so two calls with one name give one object and one socket.

  Nothing here can switch a database. There is no `db_set_db_id()` any more and
  no `db_set_default()`: the identifier comes from settings, which is frozen
  after boot, and an object is bound to its identifier at construction.
]]

local M = {}

local config = require 'includes.database.config'
local connection = require 'includes.database.connection'
local request_state = require 'includes.request_state'

local KEY = 'db.connections'

--[[ This request's connection for `name`, connecting on first use.

  Lazy on purpose. Bootstrap phase 12 connects unconditionally today, and the
  two queries a warm anonymous page still costs are that connection's own SQLite
  pragmas -- so a warm page that issues no query pays for a connection it never
  uses. Connecting on first use takes that budget to zero, which is the
  "hold a connection across requests" item answered from the other side: the
  cheapest connection is the one not opened.
]]
function M.get(name)
  local state = request_state.current()
  local pool = state[KEY]
  local key, conn

  if pool == nil then
    pool = {}
    state[KEY] = pool
  end

  -- Resolved rather than defaulted to a literal, so the default's own name is
  -- the key and `db_connection()` and `db_connection('primary')` are one object
  -- rather than two sockets to one database.
  key = name or config.default_name()

  if key == nil then
    error('database: no default connection is configured; set settings.db.default', 0)
  end

  conn = pool[key]

  if conn == nil then
    conn = connection.open(name)
    pool[key] = conn
  end

  return conn
end

--[[ Give every connection this request took back.

  Called from `ophal_request_reset()` at the end of a request. Under keepalive a
  socket belongs to one request and must be returned at its end; a connection
  that is not released is a socket that never goes back to the pool. Releasing
  also marks each object, so one kept in a module upvalue raises at its next use
  instead of reaching a socket another request now owns.
]]
function M.release_all(ok)
  local state = request_state.current()
  local pool = state[KEY]
  local released = 0

  if pool == nil then
    return 0
  end

  for _, conn in pairs(pool) do
    pcall(conn.release, conn, ok)
    released = released + 1
  end

  state[KEY] = nil

  return released
end

function M.names()
  return config.names()
end

function M.default_name()
  return config.default_name()
end

return M
