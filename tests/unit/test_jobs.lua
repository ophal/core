-- Unit tests for the deferred work queue.
--
-- The queue exists so that a stale projection stops rebuilding inline from
-- inside a public GET. What matters here is the logic around the SQL -- dedup,
-- retry, handler dispatch, and tolerating an unmigrated site -- because the
-- statements themselves are exercised against a real database by the smoke
-- suite. The one thing no test here can run is the PostgreSQL claim, so this
-- file at least pins what that statement says.

do
  local root = io.popen('pwd'):read('*l')
  local vendor_root = root .. '/tests/smoke/vendor'
  local vendor_share = vendor_root .. '/unpack/usr/share/lua/5.1'

  package.path = table.concat({
    root .. '/?.lua',
    root .. '/?/init.lua',
    vendor_root .. '/?.lua',
    vendor_root .. '/?/init.lua',
    vendor_share .. '/?.lua',
    vendor_share .. '/?/init.lua',
    package.path,
  }, ';')
end

local pass_count, fail_count = 0, 0

local function assert_eq(label, got, expected)
  if got == expected then
    pass_count = pass_count + 1
    io.write(('  ok %s\n'):format(label))
  else
    fail_count = fail_count + 1
    io.write(('  FAIL %s: expected %s, got %s\n'):format(
      label, tostring(expected), tostring(got)))
  end
end

local function assert_match(label, got, pattern)
  if tostring(got):match(pattern) then
    pass_count = pass_count + 1
    io.write(('  ok %s\n'):format(label))
  else
    fail_count = fail_count + 1
    io.write(('  FAIL %s: %q did not match %q\n'):format(
      label, tostring(got), pattern))
  end
end

local function result_of(rows)
  local index = 0

  return {
    fetch = function()
      index = index + 1
      return rows[index]
    end,
    all = function()
      return rows
    end,
  }
end

local registry = require 'includes.database.registry'
local db_fake = require 'tests.unit.db_fake'

-- A stand-in for `ophal_jobs`. It keeps rows in a Lua array and answers the
-- handful of statements the module issues; `state.missing_table` makes every
-- one of them raise the way the driver does before `005_jobs` has been run.
local function new_state()
  return {rows = {}, next_id = 1, queries = {}, missing_table = false}
end

--[[ The queue's statements, answered by name.

  Dispatch is on the statement name rather than on the SQL, which is what the
  layer made possible and what the old stub could not do: `jobs.complete`,
  `jobs.retry` and `jobs.give_up` are three UPDATEs that differ by one clause,
  and telling them apart by pattern-matching their text is exactly the
  brittleness declarations exist to remove. What the SQL itself says is pinned
  separately, under "declared statements", against the registry.
]]
local handlers = {}

function handlers.enqueue(state, args)
  -- `ON CONFLICT(active_key) DO NOTHING`, modelled the way both drivers
  -- behave: a NULL active_key never conflicts, a repeated one is dropped.
  local active_key = args[3]

  if active_key ~= nil then
    for _, row in ipairs(state.rows) do
      if row.active_key == active_key then
        return {}
      end
    end
  end

  state.rows[#state.rows + 1] = {
    id = state.next_id,
    kind = args[1],
    dedup_key = args[2],
    active_key = active_key,
    payload = args[4],
    status = args[5],
    priority = args[6],
    attempts = 0,
    available_at = args[7],
    created_at = args[8],
  }
  state.next_id = state.next_id + 1

  return {}
end

-- args: claimed_at, claimed_by, updated_at, cutoff, limit.
function handlers.claim(state, args)
  local taken = 0

  for _, row in ipairs(state.rows) do
    if taken < args[5] and row.status == 'pending'
        and (row.available_at or 0) <= args[4] then
      row.status = 'running'
      row.claimed_by = args[2]
      row.attempts = (row.attempts or 0) + 1
      taken = taken + 1
    end
  end

  return {}
end

function handlers.claimed(state, args)
  local found = {}

  for _, row in ipairs(state.rows) do
    if row.claimed_by == args[1] and row.status == args[2] then
      found[#found + 1] = row
    end
  end

  return found
end

-- args: status, updated_at, id. Clearing `active_key` is what releases the
-- dedup slot.
function handlers.complete(state, args)
  for _, row in ipairs(state.rows) do
    if row.id == args[3] then
      row.status = args[1]
      row.active_key = nil
    end
  end

  return {}
end

-- args: status, available_at, updated_at, last_error, id.
local function record_failure(state, args, clears_key)
  for _, row in ipairs(state.rows) do
    if row.id == args[5] then
      row.status = args[1]
      row.available_at = args[2]
      row.last_error = args[4]

      if clears_key then
        row.active_key = nil
      end
    end
  end

  return {}
end

-- A retrying job keeps its `active_key`, so nothing queues a second copy
-- beside it; one that has given up releases the identity for later.
function handlers.retry(state, args)
  return record_failure(state, args, false)
end

function handlers.give_up(state, args)
  return record_failure(state, args, true)
end

function handlers.active_age(state, args)
  for _, row in ipairs(state.rows) do
    if row.active_key == args[1] then
      return {{created_at = row.created_at}}
    end
  end

  return {}
end

function handlers.pending_count(state, args)
  local count = 0

  for _, row in ipairs(state.rows) do
    if row.status == args[1] or row.status == args[2] then
      count = count + 1
    end
  end

  return {{total = count}}
end

local function install_db(state)
  settings = {performance = {jobs = {retry_backoff = 30, max_attempts = 2}}}

  -- Dispatch on the statement name: `jobs.complete`, `jobs.retry` and
  -- `jobs.give_up` are three UPDATEs that differ by one clause, and telling
  -- them apart by pattern-matching their text is exactly the brittleness
  -- declarations exist to remove. `db_fake` still refuses an undeclared name.
  db_fake.install({
    statement = function(name, ...)
      local args = {...}
      local handler = handlers[(name:gsub('^jobs%.', ''))]

      state.queries[#state.queries + 1] = {statement = name, args = args}

      if state.missing_table then
        error('no such table: ophal_jobs')
      end

      return result_of(handler and handler(state, args) or {})
    end,
  }, _G)
end

local function load_jobs()
  package.loaded['includes.jobs'] = nil
  package.loaded['includes.projection'] = nil
  return require 'includes.jobs'
end

io.write '\n-- job enqueue --\n'

do
  local state = new_state()
  install_db(state)
  local jobs = load_jobs()

  assert_eq('enqueue_first', jobs.enqueue('rebuild', 'projection:content_public', {key = 'x'}), true)
  assert_eq('enqueue_row_written', #state.rows, 1)
  assert_eq('enqueue_status_pending', state.rows[1].status, 'pending')

  -- The whole point of the dedup key: every request during the stale window
  -- would otherwise queue another copy of the same rebuild. The assertion is on
  -- the row count rather than the return value, because what matters is the
  -- guarantee the unique index gives, not which branch Lua took -- `enqueue`
  -- reports success either way, since either way the rebuild is queued.
  assert_eq('enqueue_duplicate_reports_queued', jobs.enqueue('rebuild', 'projection:content_public', {key = 'x'}), true)
  assert_eq('enqueue_duplicate_no_row', #state.rows, 1)

  assert_eq('enqueue_other_key', jobs.enqueue('rebuild', 'projection:tag_listing_index', {key = 'y'}), true)
  assert_eq('enqueue_other_key_row', #state.rows, 2)
  assert_eq('enqueue_pending_count', jobs.pending_count(), 2)

  -- A job with no identity is never deduped: NULL active keys do not conflict
  -- with each other, on either driver.
  jobs.enqueue('oneoff')
  jobs.enqueue('oneoff')
  assert_eq('enqueue_without_dedup_key_always_inserts', #state.rows, 4)
end

do
  local state = new_state()
  install_db(state)
  state.missing_table = true
  local jobs = load_jobs()

  -- A site that has not run `005_jobs` must not error and must not lose the
  -- rebuild: enqueue reports that no deferral is available, and the caller
  -- rebuilds inline the way it always did.
  assert_eq('enqueue_unmigrated_false', jobs.enqueue('rebuild', 'projection:content_public'), false)
  assert_eq('enqueue_unmigrated_claim_empty', #jobs.claim('worker', 5), 0)
  assert_eq('enqueue_unmigrated_pending_zero', jobs.pending_count(), 0)
end

io.write '\n-- how long work has been waiting --\n'

do
  local state = new_state()
  install_db(state)
  local jobs = load_jobs()

  -- Nothing queued under that identity, which is also what a finished job looks
  -- like: `complete()` nulls `active_key`, so a drained queue reports nil here
  -- by the same mechanism that lets the work be queued again.
  assert_eq('active_age_absent', jobs.active_age('projection:content_public'), nil)

  jobs.enqueue('rebuild', 'projection:content_public', {key = 'x'})

  -- Just queued, so the age is the time since this second. The assertion is a
  -- bound rather than an equality because the clock can tick mid-test.
  assert_eq('active_age_fresh', jobs.active_age('projection:content_public') < 2, true)

  -- The row is what carries the age, so backdating it is what a queue nobody
  -- has drained looks like from the next request's point of view.
  state.rows[1].created_at = os.time() - 4000
  assert_eq('active_age_counts_from_created_at',
    jobs.active_age('projection:content_public') >= 4000, true)

  -- A finished job releases the identity and stops being visible here, which is
  -- what keeps a drained queue from reading as a stalled one forever.
  jobs.complete(state.rows[1].id)
  assert_eq('active_age_after_complete', jobs.active_age('projection:content_public'), nil)

  assert_eq('active_age_no_key', jobs.active_age(nil), nil)
  assert_eq('active_age_empty_key', jobs.active_age(''), nil)
end

do
  local state = new_state()
  install_db(state)
  state.missing_table = true
  local jobs = load_jobs()

  -- An unmigrated site has no queue, so there is no waiting work to report and
  -- nothing to raise about. The caller reads nil as "no live job", which sends
  -- it down the inline path it was already taking there.
  local age, err = jobs.active_age('projection:content_public')

  assert_eq('active_age_unmigrated', age, nil)
  -- And not as an error either: a missing table is "no deferral is available",
  -- which every caller already answers by working inline. Reporting it as a
  -- failure would put an error where the callers expect an absence.
  assert_eq('active_age_unmigrated_not_an_error', err, nil)
end

io.write '\n-- job claim and run --\n'

do
  local state = new_state()
  install_db(state)
  local jobs = load_jobs()
  local seen = {}

  jobs.registry_clear()
  jobs.register('rebuild', function(payload)
    seen[#seen + 1] = payload and payload.key or '?'
    return true
  end)

  jobs.enqueue('rebuild', 'a', {key = 'alpha'})
  jobs.enqueue('rebuild', 'b', {key = 'beta'})

  local claimed = jobs.claim('worker-1', 10)
  assert_eq('claim_count', #claimed, 2)
  assert_eq('claim_attempts_incremented', claimed[1].attempts, 1)
  -- A second runner must find nothing: the claim moved the rows out of
  -- `pending` before anything read them back.
  assert_eq('claim_second_runner_empty', #jobs.claim('worker-2', 10), 0)
end

do
  local state = new_state()
  install_db(state)
  local jobs = load_jobs()
  local seen = {}

  jobs.registry_clear()
  jobs.register('rebuild', function(payload)
    seen[#seen + 1] = payload.key
    return true
  end)

  jobs.enqueue('rebuild', 'a', {key = 'alpha'})

  local summary = jobs.run_pending{worker_id = 'runner'}
  assert_eq('run_ran', summary.ran, 1)
  assert_eq('run_failed', summary.failed, 0)
  assert_eq('run_handler_payload', seen[1], 'alpha')
  assert_eq('run_marked_done', state.rows[1].status, 'done')
  assert_eq('run_pending_count_zero', jobs.pending_count(), 0)

  -- Finishing releases the dedup slot, so the same work can be asked for again
  -- the next time it is needed.
  assert_eq('complete_releases_dedup_slot', state.rows[1].active_key, nil)
  jobs.enqueue('rebuild', 'a', {key = 'alpha'})
  assert_eq('complete_allows_requeue', #state.rows, 2)
end

do
  local state = new_state()
  install_db(state)
  local jobs = load_jobs()

  jobs.registry_clear()
  jobs.register('boom', function()
    error('handler exploded')
  end)

  jobs.enqueue('boom', 'boom:1')

  -- The drain runs from a cron hook, and `module_invoke_all()` cancels every
  -- later module's hook when one returns an error. A handler that raises must
  -- therefore be contained here rather than propagated.
  local summary = jobs.run_pending{worker_id = 'runner'}
  assert_eq('run_error_contained', type(summary), 'table')
  assert_eq('run_error_failed', summary.failed, 1)
  assert_eq('run_error_ran', summary.ran, 0)
  assert_match('run_error_recorded', state.rows[1].last_error, 'handler exploded')
  -- One attempt of two, so it goes back to pending with a later availability.
  assert_eq('run_error_retries', state.rows[1].status, 'pending')

  -- And the backoff is real: the retry is not due yet, so the very next drain
  -- passes it over rather than spinning on a job that just failed.
  assert_eq('run_error_backoff_holds', jobs.run_pending{worker_id = 'runner'}.claimed, 0)

  -- Once the backoff has elapsed, the second failure reaches `max_attempts` and
  -- the job stops consuming the runner instead of retrying forever.
  state.rows[1].available_at = 0
  jobs.run_pending{worker_id = 'runner'}
  assert_eq('run_error_gives_up', state.rows[1].status, 'failed')

  -- Giving up must release the identity too, or the dedup key stays poisoned
  -- and the work can never be queued again.
  assert_eq('run_error_releases_dedup_slot', state.rows[1].active_key, nil)
end

do
  local state = new_state()
  install_db(state)
  local jobs = load_jobs()

  jobs.registry_clear()
  jobs.enqueue('nosuchkind', 'nsk:1')

  local summary = jobs.run_pending{worker_id = 'runner'}
  assert_eq('run_unknown_kind_failed', summary.failed, 1)
  assert_match('run_unknown_kind_error', state.rows[1].last_error, 'no handler registered')
end

io.write '\n-- cron drain --\n'

-- `module_invoke_all()` treats a truthy second return as an error and abandons
-- every module it has not reached yet, and `system` -- which owns the drain --
-- is ordered first. So the contract `drain()` has to meet is narrower than "it
-- works": it must return nothing at all, under every outcome.
do
  local state = new_state()
  install_db(state)
  local jobs = load_jobs()
  local ran = 0

  jobs.registry_clear()
  jobs.register('rebuild', function()
    ran = ran + 1
    return true
  end)

  jobs.enqueue('rebuild', 'a')

  assert_eq('drain_returns_nothing', select('#', jobs.drain{worker_id = 'cron'}), 0)
  assert_eq('drain_ran_the_job', ran, 1)
  assert_eq('drain_emptied_the_queue', jobs.pending_count(), 0)
end

-- An unmigrated site reaches the drain on every cron run. It has to be a quiet
-- no-op there, not an error that stops session cleanup for the rest of time.
do
  local state = new_state()
  install_db(state)
  state.missing_table = true
  local jobs = load_jobs()

  assert_eq('drain_unmigrated_returns_nothing', select('#', jobs.drain()), 0)
end

-- And a queue that is broken for some other reason -- a permission, a corrupt
-- file, a driver fault -- must be logged rather than raised, for the same
-- reason. This is the case `pcall` in `drain()` exists for: `claim()` only
-- swallows a missing table, so anything else comes back out as an error.
do
  local state = new_state()
  install_db(state)
  local jobs = load_jobs()
  local logged

  db_connection = function()
    return {
      run = function() error('database is locked') end,
      try = function() return nil, 'database is locked' end,
    }
  end
  log_error = function(message, context)
    logged = context and context.event
  end

  assert_eq('drain_broken_returns_nothing', select('#', jobs.drain()), 0)
  assert_eq('drain_broken_logged', logged, 'job_drain_failed')

  log_error = nil
end

io.write '\n-- driver claim statements --\n'

do
  local sqlite = require 'includes.database.driver.lsqlite3'
  local postgresql = require 'includes.database.driver.pgmoon'
  local sqlite_compiled = registry.compile(sqlite, 'jobs.claim')
  local pg_compiled = registry.compile(postgresql, 'jobs.claim')
  local sqlite_sql = sqlite_compiled.sql
  local pg_sql = pg_compiled.sql

  -- `jobs.claim()` binds claimed_at, claimed_by, updated_at, the availability
  -- cutoff and the row limit, in that order, to whichever statement the driver
  -- compiled. If the two stop agreeing on the count, one is silently binding
  -- the wrong values.
  --
  -- Counted from the compiled statement rather than by looking for `?`, because
  -- the placeholder is the driver's business: lsqlite3 binds `?` and pgmoon
  -- renders `$1..$n`, so scanning the text answered five for one and zero for
  -- the other while both were correct.
  assert_eq('claim_sqlite_placeholders', sqlite_compiled.nparams, 5)
  assert_eq('claim_postgresql_placeholders', pg_compiled.nparams, 5)
  assert_match('claim_postgresql_is_numbered', pg_sql, '%$5')

  -- This is the only statement in the codebase that is not portable. It is one
  -- declaration with a `postgresql` override rather than a function per driver
  -- now, so what is checked is that compiling the same name for two drivers
  -- gives two different statements. `tests/bench/driver_contract.lua` runs both
  -- against real servers; this pins the text where the suite cannot.
  assert_match('claim_postgresql_skip_locked', pg_sql, 'FOR UPDATE SKIP LOCKED')
  assert_eq('claim_sqlite_no_skip_locked', sqlite_sql:match('SKIP LOCKED') == nil, true)

  assert_match('claim_sqlite_targets_pending', sqlite_sql, "status = 'pending'")
  assert_match('claim_postgresql_targets_pending', pg_sql, "status = 'pending'")
end

io.write '\n-- queue migration --\n'

do
  local registry = dofile('includes/migrations.lua')
  local jobs_migration = registry[#registry]

  assert_eq('migration_id', jobs_migration.id, '005_jobs')

  -- Dedup is a database guarantee, so the index that provides it has to exist
  -- on both drivers. Without it `ON CONFLICT(active_key)` has no arbiter and
  -- every stale request queues another rebuild.
  for _, driver in ipairs({'sqlite3', 'postgresql'}) do
    local statements = {}
    local ok = jobs_migration.up({
      driver = driver,
      db_query = function(sql)
        statements[#statements + 1] = sql
        return true
      end,
    })

    assert_eq('migration_runs_' .. driver, ok, true)
    assert_eq(
      'migration_unique_active_key_' .. driver,
      table.concat(statements, '\n'):match('CREATE UNIQUE INDEX[^\n]*\nON ophal_jobs%(active_key%)') ~= nil,
      true
    )
  end
end

io.write(('\n%d passed, %d failed\n'):format(pass_count, fail_count))

if fail_count > 0 then
  os.exit(1)
end
