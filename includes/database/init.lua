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

local config = require 'includes.database.config'
local driver_base = require 'includes.database.driver'
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

--[[ Transitional, and deliberately marked so.

  Stage 8.5 moves sixty-three call sites from ad-hoc SQL onto declared
  statements one file at a time. Until the last of them lands these keep the
  untouched files working, and they are deleted with the last call site rather
  than deprecated and left. Each one resolves the default connection implicitly,
  which is the hazard the object exists to remove -- so nothing new may call
  them.
]]
function db_query(query, ...)
  return db_connection():execute(query, ...)
end

function db_field(table_name, field_name)
  return db_connection():field(table_name, field_name)
end

function db_last_insert_id(table_name, field_name)
  return db_connection():last_insert_id(table_name, field_name)
end

-- The dialect's LIMIT spelling, for the paginated statements that still build
-- their SQL at the call site. Declared statements say `{{limit}}` instead.
function db_limit()
  return driver_base.load(config.get().driver_module).limit_clause
end

function db_schema_cache_clear()
  return db_connection():schema_cache_clear()
end
