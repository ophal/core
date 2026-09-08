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

  Each backend answers from somewhere different. SQLite has no
  `information_schema`; `pragma_table_info` is the table-valued form of
  `PRAGMA table_info` and, unlike the bare pragma, takes a bind parameter, so
  the table name is not interpolated.
]]
define('core.table_schema', {
  sql = [[SELECT column_name field_name
FROM information_schema.columns
WHERE table_name = ?]],
  sqlite3 = {
    sql = [[SELECT name field_name
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
  from the table and column, so it is the one statement here with identifiers.
]]
define('core.last_insert_id', {
  sql = 'SELECT last_insert_rowid()',
  postgresql = {sql = "SELECT CURRVAL('{table:bare}_{field:bare}_seq')"},
  mysql = {sql = 'SELECT LAST_INSERT_ID()'},
  idents = {table = true, field = true},
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

return true
