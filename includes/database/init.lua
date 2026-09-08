--[[ The application's database API.

  One accessor, `db_connection(name)`, answering with a connection object bound
  to that identifier. Every operation is a method on an object the caller is
  already holding, so no line can change which database a later line talks to.
  There is no `db_set_db_id()` and no `db_connect()`: the identifier comes from
  settings, which is frozen after boot, and connecting happens on first use.

    local db = db_connection()          -- this request's default connection
    local rs = db:run('content.load', id)

    local legacy = db_connection('legacy')   -- another driver, live at once

  Connecting is lazy and releasing is at the end of the request. Bootstrap used
  to connect unconditionally in phase 12, and the two queries a warm anonymous
  page still cost were that connection's own SQLite pragmas -- so a page that
  issued no query paid for a connection it never opened a statement on. A warm
  page now opens nothing.
]]

local router = require 'includes.database.router'
local stats = require 'includes.database.stats'

-- The framework's own statements: transactions, schema reads, the job claim,
-- `last_insert_id`. Required here so that anything holding a connection can
-- run them without knowing where they were declared.
require 'includes.database.statements'

--[[ This request's connection for `name`, or for the default when none given.

  Memoized per identifier per request, so two calls with one name give one
  object and one socket. An unknown identifier raises rather than falling back
  to the default: silently answering `db_connection('legacy')` with the site's
  own database is how an integration writes into the wrong place.
]]
function db_connection(name)
  return router.get(name)
end

-- The configured identifiers, for the CLI and `install check`.
function db_names()
  return router.names()
end

function db_default_name()
  return router.default_name()
end

--[[ Give back every connection this request took.

  Called from `shutdown_ophal()`. Under keepalive a socket belongs to one
  request and has to be returned at its end; releasing also marks each object,
  so one kept in a module upvalue raises at its next use rather than reaching a
  socket another request now owns.
]]
function db_release_all(ok)
  return router.release_all(ok)
end

-- Reports how many queries this worker has issued and how many of them still
-- read normalized tables. Public delivery should hold `normalized` at zero once
-- the worker is warm; anything else names the path that still falls through.
function db_query_stats()
  return stats.snapshot()
end

function db_query_stats_reset()
  return stats.reset()
end

--[[ Drop this request's connection's cached table schemas.

  Reached from `cache_clear_all()`. Per connection rather than per worker: the
  old cache was keyed by table name alone, so two connections whose schemas
  differ -- the migration and integration case -- shared one and the second was
  answered with the first's columns.
]]
function db_schema_cache_clear()
  return db_connection():schema_cache_clear()
end
