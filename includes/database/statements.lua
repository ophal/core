--[[ The statements the framework itself needs.

  `limit()`, `last_insert_id()`, `table_schema_sql()` and `claim_jobs_sql()` in
  `includes/database/sqlite3.lua` and `postgresql.lua` were a statement registry
  written informally for four statements: one portable form, a per-driver
  override where a dialect forces one, looked up through the active driver.
  Here they are ordinary declarations, and `claim_jobs_sql()` -- long the only
  statement in this codebase that was not portable -- stops being a special
  case and becomes a `postgresql` key like any other.
]]

local registry = require 'includes.database.registry'

local define = registry.define

-- Transactions. SQLite and MySQL accept `BEGIN`; PostgreSQL accepts it too, so
-- one portable form serves all three. They name no table, so they land in no
-- bucket and count only toward `total`.
define('core.begin', {sql = 'BEGIN', tables = {}})
define('core.commit', {sql = 'COMMIT', tables = {}})
define('core.rollback', {sql = 'ROLLBACK', tables = {}})

--[[ A table's columns.

  Each backend answers from somewhere different, so there is no portable body
  here and the base is PostgreSQL's. SQLite has no `information_schema` at all;
  `pragma_table_info` is the table-valued form of `PRAGMA table_info` and,
  unlike the bare pragma, takes a bind parameter, so the table name is not
  interpolated.

  `information_schema.columns` spans every schema on a PostgreSQL database and
  every *database* on a MySQL server, so both are scoped to the one this
  connection is attached to. Unscoped, a same-named table elsewhere on the
  server contributes its columns to the answer -- and this answer is
  `db_field()`, which is the whitelist `load_by_field` interpolates a column
  name through. The old `table_schema_sql()` on both drivers was unscoped; it
  was invisible while SQLite was the only backend anything ran against.
]]
define('core.table_schema', {
  sql = [[SELECT column_name AS field_name
FROM information_schema.columns
WHERE table_name = ? AND table_schema = CURRENT_SCHEMA()]],
  mysql = {
    sql = [[SELECT column_name AS field_name
FROM information_schema.columns
WHERE table_name = ? AND table_schema = DATABASE()]],
  },
  sqlite3 = {
    sql = [[SELECT name AS field_name
FROM pragma_table_info(?)]],
  },
  -- `information_schema` is neither site content nor framework bookkeeping.
  -- Naming no table keeps schema reads out of every bucket while still counting
  -- toward the total, which is what the parser did with them.
  tables = {},
})

--[[ The id a just-finished INSERT produced.

  Three genuinely different answers, which is why this was a per-driver function
  and stays a per-dialect override. PostgreSQL needs the sequence's name, built
  from the table and column, so it is the one statement here with identifiers --
  and the other two dialects take them and have nowhere to put them, which is
  what keeps `db:last_insert_id(table, field)` one shape everywhere.

  All three alias the value as `id`. Without that, reading it means taking the
  first column positionally, which a hash-row driver cannot do.

  Both identifiers are `registry.trusted`: they name the table a caller has just
  inserted into and its primary key, and every caller writes both itself --
  `db:last_insert_id('content', 'id')`. Nothing here comes from a request, which
  is the claim `trusted` exists to make in a place a reader and a grep can both
  find. A schema resolver would be the wrong guard rather than a stricter one:
  the sequence name it builds is not a table, so there is nothing for
  `connection:table()` to answer about.
]]
define('core.last_insert_id', {
  sql = 'SELECT last_insert_rowid() AS id',
  postgresql = {sql = "SELECT CURRVAL('{table:bare}_{field:bare}_seq') AS id"},
  mysql = {sql = 'SELECT LAST_INSERT_ID() AS id'},
  idents = {table = registry.trusted, field = registry.trusted},
  order = {'table', 'field'},
  tables = {},
})

--[[ Claim pending jobs.

  PostgreSQL's `FOR UPDATE SKIP LOCKED` lets several runners drain the queue at
  once without contending for the same row. SQLite has no equivalent and
  serializes on the write lock that `busy_timeout` and WAL already manage, which
  is sound because SQLite is the single-node case. MySQL 8 has `SKIP LOCKED`
  too, but MariaDB does not, and the vendored lab backend is MariaDB 10.11 --
  so the portable form is what MySQL gets until stage 8.6 measures a real
  server and can tell the two apart.

  Parameters, in order: claimed_at, claimed_by, updated_at, the available_at
  cutoff, and the row limit.
]]
define('jobs.claim', {
  sql = [[UPDATE ophal_jobs
SET status = 'running',
  claimed_at = ?,
  claimed_by = ?,
  attempts = attempts + 1,
  updated_at = ?
WHERE id IN (
  SELECT id FROM ophal_jobs
  WHERE status = 'pending' AND available_at <= ?
  ORDER BY priority, id
  LIMIT ?
)]],
  postgresql = {
    sql = [[UPDATE ophal_jobs
SET status = 'running',
  claimed_at = ?,
  claimed_by = ?,
  attempts = attempts + 1,
  updated_at = ?
WHERE id IN (
  SELECT id FROM ophal_jobs
  WHERE status = 'pending' AND available_at <= ?
  ORDER BY priority, id
  LIMIT ?
  FOR UPDATE SKIP LOCKED
)]],
  },
  tables = {'ophal_jobs'},
})

--[[ Queue a job, unless one with the same identity is already live.

  Dedup is the database's. `active_key` carries a job's identity while it is
  live and is nulled when it finishes, so a single UNIQUE index over it plus
  `ON CONFLICT(active_key) DO NOTHING` gives "at most one live job per identity"
  with no read-then-write race. NULLs are distinct in a unique index on both
  drivers, so a job with no dedup key is never deduped.
]]
define('jobs.enqueue', {
  sql = [[INSERT INTO ophal_jobs(
  kind, dedup_key, active_key, payload, status, priority, attempts,
  available_at, created_at, updated_at
) VALUES(?, ?, ?, ?, ?, ?, 0, ?, ?, ?)
ON CONFLICT(active_key) DO NOTHING]],
  tables = {'ophal_jobs'},
})

define('jobs.claimed', {
  sql = [[SELECT * FROM ophal_jobs
WHERE claimed_by = ? AND status = ?
ORDER BY id]],
  tables = {'ophal_jobs'},
})

-- Clearing `active_key` is what releases the dedup slot, so the next time the
-- same work becomes necessary it can be queued again.
define('jobs.complete', {
  sql = [[UPDATE ophal_jobs
SET status = ?, active_key = NULL, claimed_by = NULL, updated_at = ?
WHERE id = ?]],
  tables = {'ophal_jobs'},
})

--[[ Hand a job back after a failure, in the two shapes that differ by one line.

  A retrying job keeps its `active_key`, so nothing queues a second copy
  alongside it. A job that has given up releases the key instead: the work may
  well still be needed, and a later request must be able to ask for it again
  rather than find the identity permanently poisoned.

  Two declarations rather than one body with the clause formatted in, because
  the difference is fixed at the call site by a condition the statement cannot
  see, and a statement that is formatted per call is a statement that is
  compiled per call.
]]
define('jobs.retry', {
  sql = [[UPDATE ophal_jobs
SET status = ?, claimed_by = NULL, available_at = ?, updated_at = ?,
  last_error = ?
WHERE id = ?]],
  tables = {'ophal_jobs'},
})

define('jobs.give_up', {
  sql = [[UPDATE ophal_jobs
SET status = ?, active_key = NULL, claimed_by = NULL, available_at = ?,
  updated_at = ?, last_error = ?
WHERE id = ?]],
  tables = {'ophal_jobs'},
})

--[[ The age of the live job row for an identity.

  At most one row can be live per identity and `complete()` nulls `active_key`,
  so a row older than the rebuild marker's own lifetime means the marker lapsed
  with nothing having run in between -- which is how a site whose cron has
  stopped finds its way back to rebuilding inline.
]]
define('jobs.active_age', {
  sql = 'SELECT created_at FROM ophal_jobs WHERE active_key = ?',
  tables = {'ophal_jobs'},
})

define('jobs.pending_count', {
  sql = [[SELECT count(*) AS total FROM ophal_jobs
WHERE status = ? OR status = ?]],
  tables = {'ophal_jobs'},
})

--[[ Routes: the normalized source, and the index projected from it.

  `route_alias` and `route_redirect` are the source of truth an administrator
  edits. `route_index` is the projection both are read through on a request, and
  it is loaded once per worker rather than once per request -- so the statements
  below are write-path and cold-start work, not per-request work.

  The redirect insert that carries an explicit id named a column `alias`, which
  `route_redirect` does not have: every other statement in the file spells it
  `target`, and so does the row that comes back from a SELECT. It was unreachable
  in this workspace because `route_redirects_storage` defaults to false and no
  shipped schema creates the table, so nothing ever ran it.
]]
define('route.alias_read', {
  sql = 'SELECT * FROM route_alias WHERE id = ?',
  tables = {'route_alias'},
})

define('route.aliases_all', {
  sql = 'SELECT * FROM route_alias',
  tables = {'route_alias'},
})

define('route.alias_create', {
  sql = [[INSERT INTO route_alias(source, alias, language)
VALUES(?, ?, ?)]],
  tables = {'route_alias'},
})

define('route.alias_create_with_id', {
  sql = [[INSERT INTO route_alias(id, source, alias, language)
VALUES(?, ?, ?, ?)]],
  tables = {'route_alias'},
})

define('route.alias_update', {
  sql = [[UPDATE route_alias SET source = ?, alias = ?, language = ?
WHERE id = ?]],
  tables = {'route_alias'},
})

define('route.alias_delete', {
  sql = 'DELETE FROM route_alias WHERE id = ?',
  tables = {'route_alias'},
})

define('route.redirect_read', {
  sql = 'SELECT * FROM route_redirect WHERE id = ?',
  tables = {'route_redirect'},
})

define('route.redirects_all', {
  sql = 'SELECT * FROM route_redirect',
  tables = {'route_redirect'},
})

define('route.redirect_create', {
  sql = [[INSERT INTO route_redirect(source, target, language, type)
VALUES(?, ?, ?, ?)]],
  tables = {'route_redirect'},
})

define('route.redirect_create_with_id', {
  sql = [[INSERT INTO route_redirect(id, source, target, language, type)
VALUES(?, ?, ?, ?, ?)]],
  tables = {'route_redirect'},
})

define('route.redirect_update', {
  sql = [[UPDATE route_redirect SET source = ?, target = ?, language = ?, type = ?
WHERE id = ?]],
  tables = {'route_redirect'},
})

define('route.redirect_delete', {
  sql = 'DELETE FROM route_redirect WHERE id = ?',
  tables = {'route_redirect'},
})

--[[ The route index, one statement per kind rather than one per kind and shape.

  `kind` was a bind parameter in the writes and a literal in the two reads, so
  the same projection was addressed two ways. It binds everywhere now, which is
  one statement instead of two and one compiled form instead of two.
]]
define('route.index_read', {
  sql = 'SELECT * FROM route_index WHERE kind = ?',
  tables = {'route_index'},
})

define('route.index_insert', {
  sql = [[INSERT INTO route_index(kind, source, target, language, http_code, updated_at)
VALUES(?, ?, ?, ?, ?, ?)]],
  tables = {'route_index'},
})

define('route.index_delete', {
  sql = 'DELETE FROM route_index WHERE kind = ? AND source = ?',
  tables = {'route_index'},
})

define('route.index_clear', {
  sql = 'DELETE FROM route_index WHERE kind = ?',
  tables = {'route_index'},
})

--[[ Projection versions.

  A version is a unix second, and `projection.touch()` writes it as one upsert
  rather than a DELETE and an INSERT: `projection_key` is the primary key on
  both drivers and `excluded` is spelled the same way in SQLite and PostgreSQL,
  so it is one portable statement. That halves what a touch costs, and it closes
  the window the pair left open -- between the DELETE and the INSERT the key had
  no row at all, and a peer worker reading it there negative-cached the miss for
  `projection_version_miss_ttl` seconds. An upsert never shows an absent row,
  and a failed one leaves the old version standing.
]]
define('projection.version', {
  sql = 'SELECT version FROM projection_version WHERE projection_key = ?',
  tables = {'projection_version'},
})

define('projection.touch', {
  sql = [[INSERT INTO projection_version(projection_key, version, updated_at)
VALUES(?, ?, ?)
ON CONFLICT(projection_key) DO UPDATE SET
  version = excluded.version,
  updated_at = excluded.updated_at]],
  tables = {'projection_version'},
})

return true
