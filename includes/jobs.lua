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

--[[ Every statement here, in the shape this module needs.

  Jobs run from a cron request that must not 500 because the queue table is
  missing, so nothing raises: `db:try()` is the layer's own `nil, err` form and
  resolving the connection is guarded the same way, because a site with no
  database configured must reach "no deferral is available" rather than an
  error.
]]
local function run(name, ...)
  local ok, db = pcall(db_connection)

  if not ok then
    return nil, db
  end

  return db:try(name, ...)
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
  plus an error otherwise. Both mean the rebuild is on the queue; neither means
  anything is going to take it off. A caller that has to tell a fresh enqueue
  from one that landed on a row nobody has drained asks `active_age()`.

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

  rs, err = run('jobs.enqueue',
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
  single-node dev, CLI, test and low-scale case. The two forms are the
  `postgresql` override on `jobs.claim`.
]]
function M.claim(worker_id, limit)
  local now = time()
  local rs, err

  worker_id = tostring(worker_id or 'unknown')

  rs, err = run('jobs.claim', now, worker_id, now, now, claim_limit(limit))

  if not rs then
    if missing_table(err) then
      return {}
    end

    return nil, err
  end

  rs, err = run('jobs.claimed', worker_id, RUNNING)

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
  local rs, err = run('jobs.complete', DONE, now, id)

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

  -- A job that has given up releases its `active_key`; a retrying one keeps it.
  -- Two declarations rather than one body with a clause formatted into it, so
  -- neither is built or compiled per call.
  rs, err = run(status == FAILED and 'jobs.give_up' or 'jobs.retry',
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

--[[ Run whatever is waiting, from a cron request, without ever breaking cron.

  This exists instead of calling `run_pending()` from the hook directly because
  of what `module_invoke_all()` does with a hook's return value, and because
  `system` -- which owns the drain -- is always ordered first, so it is the one
  module whose return value can cost every other module its hook.

  Two shapes are unsafe there, both pinned in `test_module_order.lua`: a truthy
  second return is read as an error and abandons every module the loop has not
  reached yet, and a table returned as the first value is walked as a set of
  route-like records and stamped with `v.module`, which raises on a summary
  whose values are numbers. So this returns nothing at all, and what happened
  goes to the log instead.

  The hook as written calls this as a statement and discards what it gets, so
  neither shape can reach `module_invoke_all()` today. That is why this is a
  contract rather than a bug fix: it makes `return jobs.drain()` -- the obvious
  way to write that line, and the way a later edit is likely to write it --
  safe by construction rather than by the accident of a missing `return`.
]]
function M.drain(options)
  -- Both failure shapes end up here. `run_pending()` returns `nil, err` when
  -- the queue cannot be read at all, and raises only if something below it
  -- does; a `pcall` alone would catch the second and silently discard the
  -- first, which is the more likely of the two.
  local ok, result, err = pcall(M.run_pending, options)

  if not ok or result == nil then
    if not ok then
      err = result
    end

    if err ~= nil and type(log_error) == 'function' then
      log_error('job drain failed', {event = 'job_drain_failed', error = err})
    end

    return
  end

  if result.claimed > 0 and type(log_notice) == 'function' then
    log_notice('job drain completed', {
      event = 'job_drain_completed',
      claimed = result.claimed,
      ran = result.ran,
      failed = result.failed,
    })
  end
end

--[[ How long a live job with this identity has been waiting, in seconds.

  nil when nothing with that identity is live, which is both "it was never
  queued" and "it was queued and has since finished" -- `active_key` is nulled
  when a job leaves the queue, so a finished job is invisible here by the same
  mechanism that stops it deduplicating new work.

  This exists because a successful `enqueue()` does not mean anything is going
  to run. It reports success for a deduplicated insert too, so a caller that
  treats it as "the rebuild is scheduled" has no way to notice that the row it
  deduplicated onto has been sitting there since before the site's cron stopped
  working. The age is the evidence: at most one row can be live per identity,
  so if this one is older than the window the caller was willing to wait, the
  drain is not running.
]]
function M.active_age(active_key)
  local rs, err, row

  if active_key == nil or active_key == '' then
    return nil
  end

  rs, err = run('jobs.active_age', tostring(active_key))

  if not rs then
    if missing_table(err) then
      return nil
    end

    return nil, err
  end

  row = rs:fetch(true)

  if not row or row.created_at == nil then
    return nil
  end

  return time() - (tonumber(row.created_at) or 0)
end

--[[ How much work is waiting. Used by the CLI and by tests; not on the request
  path.
]]
function M.pending_count()
  local rs, err = run('jobs.pending_count', PENDING, RUNNING)

  if not rs then
    if missing_table(err) then
      return 0
    end

    return nil, err
  end

  return (rs:fetch(true) or {}).total or 0
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
