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

-- A table name follows one of these.
local TABLE_KEYWORDS = {
  FROM = true,
  INTO = true,
  JOIN = true,
  UPDATE = true,
}

-- Keywords that can also follow one, in a derived table or an INSERT..SELECT.
-- Without this a `FROM (SELECT ...)` would report a table named `select`.
local NOT_A_TABLE = {
  SELECT = true,
  VALUES = true,
}

local enabled
local counts

local function new_counts()
  return {total = 0, projection = 0, normalized = 0, tables = {}}
end

counts = new_counts()

function M.is_projection_table(name)
  return PROJECTION_TABLES[name] == true
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

-- A query counts as normalized if it names any non-projection table, so a join
-- back to source data is not hidden by the projection table beside it.
function M.record(sql)
  local names, normalized

  if not stats_enabled() then
    return
  end

  names = M.tables(sql)
  counts.total = counts.total + 1

  for _, name in ipairs(names) do
    counts.tables[name] = (counts.tables[name] or 0) + 1

    if not M.is_projection_table(name) then
      normalized = true
    end
  end

  if normalized then
    counts.normalized = counts.normalized + 1
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
    tables = tables,
  }
end

return M
