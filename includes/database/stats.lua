-- Query accounting for the cache-first delivery budget.
--
-- Phase 4 of the performance plan exits when normal anonymous delivery stops
-- reading normalized tables. That is a claim about every query a request makes,
-- not about the handful of query shapes a test happens to name, so the
-- classification lives here where both `db_query()` and the budget tests share
-- one definition of what counts as normalized.

local M = {}

-- Read models the projection layer maintains. Everything else is normalized
-- source data that a warm public request should not have to reconstruct.
local PROJECTION_TABLES = {
  content_public = true,
  projection_version = true,
  route_index = true,
  tag_listing_index = true,
}

-- Tables the framework keeps for its own bookkeeping. They hold no site content
-- in either form, so counting them as normalized would say a page reconstructed
-- source data when it did nothing of the sort, and counting them as projection
-- would let queue traffic hide inside the number Phase 4 holds at zero.
--
-- This bucket exists because deferral puts a write on the read path on purpose:
-- a request that finds a projection stale enqueues a job instead of rebuilding.
-- That enqueue has to be visible in the budget -- it is not free -- and it has
-- to be distinguishable from the fallback's normalized reads, because the two
-- move for different reasons.
local INFRASTRUCTURE_TABLES = {
  ophal_jobs = true,
  ophal_migrations = true,
}

-- A table name follows one of these.
local TABLE_KEYWORDS = {
  FROM = true,
  INTO = true,
  JOIN = true,
  UPDATE = true,
}

-- Keywords that can also follow one, in a derived table, an INSERT..SELECT or
-- an upsert. Without this a `FROM (SELECT ...)` would report a table named
-- `select`, and the `ON CONFLICT ... DO UPDATE SET` in `projection.touch()` a
-- table named `set` -- which, being no projection, would count every upsert as
-- a normalized read.
local NOT_A_TABLE = {
  SELECT = true,
  SET = true,
  VALUES = true,
}

local enabled
local counts

local function new_counts()
  return {total = 0, projection = 0, normalized = 0, infrastructure = 0, tables = {}}
end

counts = new_counts()

function M.is_projection_table(name)
  return PROJECTION_TABLES[name] == true
end

function M.is_infrastructure_table(name)
  return INFRASTRUCTURE_TABLES[name] == true
end

-- Every table named in `sql`, in the order it appears. Scanning token pairs
-- rather than anchoring one pattern keeps joins and subqueries in scope, and
-- makes keyword case irrelevant.
function M.tables(sql)
  local names, previous = {}, ''

  for token in tostring(sql or ''):gmatch('[%w_]+') do
    local upper = token:upper()

    if TABLE_KEYWORDS[previous] and not NOT_A_TABLE[upper] then
      names[#names + 1] = token:lower()
    end

    previous = upper
  end

  return names
end

-- Counting is off unless `settings.performance.query_stats` is true, so the
-- cost on a normal request is one boolean test per query. The setting is read
-- once per worker because settings do not change at runtime.
local function stats_enabled()
  if enabled == nil then
    enabled = (((settings or {}).performance or {}).query_stats == true)
  end

  return enabled
end

-- One query lands in exactly one bucket, and the buckets are ordered rather
-- than counted separately: a query counts as normalized if it names any source
-- table, so a join back to source data is not hidden by the projection table
-- beside it, and as infrastructure if it names no source table but touches the
-- framework's own bookkeeping. Only a query that reads nothing but read models
-- counts as projection.
--
-- The order is what makes each number mean something on its own. If a mixed
-- query counted in two buckets, `normalized` would stop being the count of
-- requests that reconstructed source data, which is the claim Phase 4 rests on.
function M.record(sql)
  local names, normalized, infrastructure

  if not stats_enabled() then
    return
  end

  names = M.tables(sql)
  counts.total = counts.total + 1

  for _, name in ipairs(names) do
    counts.tables[name] = (counts.tables[name] or 0) + 1

    if M.is_infrastructure_table(name) then
      infrastructure = true
    elseif not M.is_projection_table(name) then
      normalized = true
    end
  end

  if normalized then
    counts.normalized = counts.normalized + 1
  elseif infrastructure then
    counts.infrastructure = counts.infrastructure + 1
  elseif #names > 0 then
    counts.projection = counts.projection + 1
  end
end

function M.reset()
  enabled = nil
  counts = new_counts()
end

function M.snapshot()
  local tables = {}

  for name, count in pairs(counts.tables) do
    tables[name] = count
  end

  return {
    total = counts.total,
    projection = counts.projection,
    normalized = counts.normalized,
    infrastructure = counts.infrastructure,
    tables = tables,
  }
end

return M
