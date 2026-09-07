--[[ Deferred work queue.

  Phase 3 made public reads capable of writing: when a projection's version
  falls behind its source, `projection.ensure()` rebuilds it from inside
  whatever request noticed, and those rebuilds are unbounded in the size of the
  table they read. This is where that work goes instead.

  The module tolerates its own table being absent. A site that has not run
  `005_jobs` gets `false` from `enqueue()`, and the caller rebuilds inline the
  way it always did, so nothing here changes behavior until the migration runs.
]]

local M = {}

local projection = require 'includes.projection'
local json = require 'dkjson'
local time = os.time
local type, pcall, tostring, tonumber = type, pcall, tostring, tonumber
local ipairs, error = ipairs, error

local PENDING = 'pending'
local RUNNING = 'running'
local DONE = 'done'
local FAILED = 'failed'
local DEFAULT_CLAIM_LIMIT = 20
local DEFAULT_MAX_ATTEMPTS = 5
local DEFAULT_RETRY_BACKOFF = 60

local handlers = {}

-- `db_query()` raises rather than returning `nil, err`, which is why
-- `projection.query` wraps it the same way. Jobs run from a cron request that
-- must not 500 because a table is missing, so every statement goes through
-- this.
local function query(sql, ...)
  local ok, result = pcall(db_query, sql, ...)

  if not ok then
    return nil, result
  end

  return result
end

-- A queue that has not been migrated is not an error. It means "no deferral is
-- available", and every caller answers that by doing the work inline.
local function missing_table(err)
  return projection.is_missing_table(err, 'ophal_jobs')
end

local function settings_table()
  return ((settings or {}).performance or {}).jobs or {}
end

local function claim_limit(limit)
  limit = tonumber(limit) or tonumber(settings_table().claim_limit) or DEFAULT_CLAIM_LIMIT

  if limit < 1 then
    return DEFAULT_CLAIM_LIMIT
  end

  return limit
end

local function max_attempts()
  local value = tonumber(settings_table().max_attempts) or DEFAULT_MAX_ATTEMPTS

  if value < 1 then
    return DEFAULT_MAX_ATTEMPTS
  end

  return value
end

local function retry_backoff()
  local value = tonumber(settings_table().retry_backoff)

  if value == nil or value < 0 then
    return DEFAULT_RETRY_BACKOFF
  end

  return value
end

--[[ Register a handler for a job kind.

  Handlers are looked up by kind at run time, so a module adds work to the queue
  without this file knowing what the work is.
]]
function M.register(kind, handler)
  if type(kind) ~= 'string' or kind == '' then
    return nil, 'a job kind must be a non-empty string'
  end

  if type(handler) ~= 'function' then
    return nil, 'a job handler must be a function'
  end

  handlers[kind] = handler

  return true
end

function M.handler(kind)
  return handlers[kind]
end

--[[ Queue one job, unless an equivalent one is already live.

  Returns true when the work is queued -- whether this call wrote the row or
  found it already there -- false when there is no queue to write to, and nil
  plus an error otherwise. Callers do not need to tell "queued" from "already
  queued": both mean the rebuild will happen.

  Dedup is the database's job, not this function's. `active_key` carries the
  identity while the job is live and is nulled when it finishes, and NULLs are
  distinct in a unique index on both drivers, so `ON CONFLICT DO NOTHING`
  against that one column is an exact "at most one live job per identity" with
  no read-then-write race to lose.
]]
function M.enqueue(kind, dedup_key, payload, priority)
  local now = time()
  local encoded, rs, err

  if type(kind) ~= 'string' or kind == '' then
    return nil, 'a job kind must be a non-empty string'
  end

  dedup_key = dedup_key and tostring(dedup_key) or nil

  if payload == nil then
    encoded = nil
  else
    encoded = json.encode(payload)
  end

  rs, err = query([[
INSERT INTO ophal_jobs(
  kind, dedup_key, active_key, payload, status, priority, attempts,
  available_at, created_at, updated_at
) VALUES(?, ?, ?, ?, ?, ?, 0, ?, ?, ?)
ON CONFLICT(active_key) DO NOTHING]],
    kind,
    dedup_key,
    dedup_key,
    encoded,
    PENDING,
    tonumber(priority) or 0,
    now,
    now,
    now
  )

  if not rs then
    if missing_table(err) then
      return false
    end

    return nil, err
  end

  return true
end

--[[ Take ownership of up to `limit` waiting jobs.

  The claim is the one place the two drivers differ. PostgreSQL uses
  `FOR UPDATE SKIP LOCKED` so concurrent runners never contend for the same
  row; SQLite has no equivalent and relies on `busy_timeout` plus WAL to
  serialize writers, which is sound because a SQLite deployment is the
  single-node dev, CLI, test and low-scale case. See `db_claim_jobs_sql()`.
]]
function M.claim(worker_id, limit)
  local now = time()
  local rs, err

  worker_id = tostring(worker_id or 'unknown')

  rs, err = query(db_claim_jobs_sql(), now, worker_id, now, now, claim_limit(limit))

  if not rs then
    if missing_table(err) then
      return {}
    end

    return nil, err
  end

  rs, err = query(
    'SELECT * FROM ophal_jobs WHERE claimed_by = ? AND status = ? ORDER BY id',
    worker_id,
    RUNNING
  )

  if not rs then
    if missing_table(err) then
      return {}
    end

    return nil, err
  end

  return rs:all(true) or {}
end

--[[ Mark a job finished.

  Clearing `active_key` is what releases the dedup slot, so the next time the
  same work becomes necessary it can be queued again.
]]
function M.complete(id)
  local now = time()
  local rs, err = query(
    'UPDATE ophal_jobs SET status = ?, active_key = NULL, claimed_by = NULL, updated_at = ? WHERE id = ?',
    DONE,
    now,
    id
  )

  if not rs then
    if missing_table(err) then
      return false
    end

    return nil, err
  end

  return true
end

--[[ Hand a job back after a failure.

  It returns to `pending` with a later `available_at` until it has been tried
  `max_attempts` times, then stays `failed` so a permanently broken job stops
  consuming the runner.

  A retrying job keeps its `active_key`, so nothing queues a second copy
  alongside it. A job that has given up releases the key instead: the work may
  well still be needed, and a later request must be able to ask for it again
  rather than find the identity permanently poisoned.
]]
function M.fail(id, job_error, attempts)
  local now = time()
  local status = PENDING
  local available_at = now + retry_backoff()
  local rs, err

  if (tonumber(attempts) or 0) >= max_attempts() then
    status = FAILED
    available_at = now
  end

  rs, err = query(([[
UPDATE ophal_jobs
SET status = ?, %s claimed_by = NULL, available_at = ?, updated_at = ?, last_error = ?
WHERE id = ?]]):format(status == FAILED and 'active_key = NULL,' or ''),
    status,
    available_at,
    now,
    job_error and tostring(job_error) or nil,
    id
  )

  if not rs then
    if missing_table(err) then
      return false
    end

    return nil, err
  end

  return status
end

local function decode_payload(job)
  local decoded

  if job.payload == nil or job.payload == '' then
    return nil
  end

  decoded = json.decode(job.payload, 1, nil)

  return decoded
end

--[[ Claim and run whatever is waiting.

  Returns a count of jobs run and jobs failed. It never raises: a handler that
  errors marks its own job and the drain moves on, because the caller is a cron
  hook and `module_invoke_all()` cancels every later module's hook when one
  returns an error.
]]
function M.run_pending(options)
  local ran, failed = 0, 0
  local jobs, err

  options = options or {}

  jobs, err = M.claim(options.worker_id, options.limit)

  if not jobs then
    return nil, err
  end

  for _, job in ipairs(jobs) do
    local handler = handlers[job.kind]
    local ok, handler_err

    if handler == nil then
      M.fail(job.id, ('no handler registered for job kind %q'):format(tostring(job.kind)), job.attempts)
      failed = failed + 1
    else
      ok, handler_err = pcall(handler, decode_payload(job), job)

      if ok and handler_err ~= false then
        M.complete(job.id)
        ran = ran + 1
      else
        M.fail(job.id, ok and 'handler declined the job' or handler_err, job.attempts)
        failed = failed + 1
      end
    end
  end

  return {ran = ran, failed = failed, claimed = #jobs}
end

--[[ How much work is waiting. Used by the CLI and by tests; not on the request
  path.
]]
function M.pending_count()
  local rs, err = query(
    'SELECT count(*) FROM ophal_jobs WHERE status = ? OR status = ?',
    PENDING,
    RUNNING
  )

  if not rs then
    if missing_table(err) then
      return 0
    end

    return nil, err
  end

  return (rs:fetch() or {})[1] or 0
end

-- Test seam: the handler registry is module state, and a unit test that
-- registers a kind would otherwise leak it into the next test in the file.
function M.registry_clear()
  handlers = {}
end

M.PENDING = PENDING
M.RUNNING = RUNNING
M.DONE = DONE
M.FAILED = FAILED

return M
