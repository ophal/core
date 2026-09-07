local _M = {}

function _M.last_insert_id(tbl_name, field)
  local sth, err, row

  sth, err = db_query('SELECT CURRVAL(?)', tbl_name .. '_' .. field .. '_seq')
  if err then
    return nil, err
  else
    row = sth:fetch()
    return row[1]
  end
end

function _M.limit()
  return ' OFFSET ? LIMIT ?'
end

function _M.table_schema_sql()
  return [[SELECT column_name field_name
FROM information_schema.columns
WHERE table_name = ?]]
end

-- The job claim. `FOR UPDATE SKIP LOCKED` is what lets several runners drain
-- the queue at once without contending for the same row, and it is the only
-- statement in the codebase that is not portable to SQLite -- which is why it
-- is isolated to this one function rather than written inline where it is used.
--
-- Parameters, in order: claimed_at, claimed_by, updated_at, the available_at
-- cutoff, and the row limit.
function _M.claim_jobs_sql()
  return [[UPDATE ophal_jobs
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
)]]
end

return _M
