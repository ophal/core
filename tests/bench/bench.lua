--[[ What each candidate driver costs, serially and under concurrency.

  Run through `tests/bench/run_bench.sh`, which sets the paths and makes sure
  the backends are up. It reports two numbers per workload because they answer
  different questions:

  - **serial ops/sec** is per-call overhead. A blocking C binding usually wins
    it, because it has no coroutine to yield through and no Lua-side protocol
    to encode.
  - **concurrent ops/sec** is what a worker can actually deliver while several
    requests are in flight. A blocking driver holds the worker for the whole
    round trip, so its concurrent number is roughly its serial one however many
    clients arrive; a cosocket driver overlaps the waiting.

  Only the second is a claim about a web runtime. A bench that reported the
  first alone would recommend LuaDBI and be wrong, which is the trap this file
  exists to avoid falling into.
]]

local drivers = require 'tests.bench.drivers'

local ITERATIONS = tonumber(os.getenv('OPHAL_BENCH_ITERATIONS') or '') or 2000
local CONCURRENCY = tonumber(os.getenv('OPHAL_BENCH_CONCURRENCY') or '') or 25
local PAGE_SIZE = tonumber(os.getenv('OPHAL_BENCH_PAGE') or '') or 100
local SEED_ROWS = tonumber(os.getenv('OPHAL_BENCH_ROWS') or '') or 500
local ONLY = os.getenv('OPHAL_BENCH_ONLY')

local function now()
  ngx.update_time()
  return ngx.now()
end

local report = {}

local function record(candidate, workload, mode, ops, seconds, failures)
  report[#report + 1] = {
    candidate = candidate,
    workload = workload,
    mode = mode,
    ops = ops,
    seconds = seconds,
    failures = failures or 0,
    rate = seconds > 0 and (ops / seconds) or 0,
  }
end

local function seed(adapter)
  for _, statement in ipairs(drivers.schema[adapter.backend]) do
    local ok, err = pcall(adapter.ddl, statement)
    if not ok then
      error(('%s: schema failed: %s'):format(adapter.name, tostring(err)))
    end
  end

  for i = 1, SEED_ROWS do
    adapter.insert('seed ' .. i)
  end
end

local function serial(adapter, workload, fn)
  local started = now()
  local completed, failures, last_error = 0, 0, nil

  for i = 1, ITERATIONS do
    local ok, err = pcall(fn, i)
    if ok then
      completed = completed + 1
    else
      failures = failures + 1
      last_error = err
    end
  end

  record(adapter.name, workload, 'serial', completed, now() - started, failures)

  if failures > 0 then
    io.write(('  %-28s serial %s: %d of %d failed (%s)\n'):format(
      adapter.name, workload, failures, ITERATIONS, tostring(last_error)))
  end
end

--[[ The same work, spread over `CONCURRENCY` light threads.

  The *same* work: thread `n` takes iterations `(n-1) * per_thread + 1` upward,
  so the union across threads is exactly the sequence the serial run performed.
  Handing every thread `1..per_thread` instead made each of them write identical
  values to identical rows, which MySQL skips as a no-op update and SQLite
  serves from one hot page -- two blocking drivers appeared to scale with
  concurrency, which is the one thing a blocking driver cannot do.

  Each thread gets its own connection, because that is what a worker serving
  concurrent requests has: one per request in flight. A blocking driver still
  runs them one after another -- it never yields -- so its concurrent rate lands
  on top of its serial one, and that flat line is the finding.

  Only operations that actually returned are counted. A thread that raises --
  SQLite answering "database is locked" to the fiftieth writer is the ordinary
  case -- would otherwise have its whole quota counted as work done, which
  turned a driver that cannot do the job into the fastest one in the table.
]]
local function concurrent(candidate, workload, fn)
  local per_thread = math.floor(ITERATIONS / CONCURRENCY)
  local threads = {}
  local adapters = {}
  local completed = {}
  local failures, last_error = 0, nil
  local started, elapsed, total

  for _ = 1, CONCURRENCY do
    local adapter = candidate.build()
    local ok, err = adapter.connect()
    if not ok then
      for _, open in ipairs(adapters) do open.close() end
      return nil, err
    end
    adapters[#adapters + 1] = adapter
  end

  started = now()

  for index = 1, CONCURRENCY do
    completed[index] = 0
    threads[index] = ngx.thread.spawn(function()
      local adapter = adapters[index]
      local first = (index - 1) * per_thread
      for offset = 1, per_thread do
        local i = first + offset
        local ok, err = pcall(fn, adapter, i)
        if not ok then
          return nil, err
        end
        completed[index] = completed[index] + 1
      end
      return true
    end)
  end

  total = 0
  for index, thread in ipairs(threads) do
    local ok, res, err = ngx.thread.wait(thread)
    if not ok or res == nil then
      failures = failures + (per_thread - completed[index])
      last_error = err or res
    end
    total = total + completed[index]
  end

  elapsed = now() - started

  record(adapters[1].name, workload, 'concurrent', total, elapsed, failures)

  if failures > 0 then
    io.write(('  %-28s concurrent %s: %d of %d failed (%s)\n'):format(
      adapters[1].name, workload, failures, per_thread * CONCURRENCY, tostring(last_error)))
  end

  for _, adapter in ipairs(adapters) do
    adapter.close()
  end

  return true
end

local WORKLOADS = {
  {
    name = 'point select',
    serial = function(adapter) return function(i) adapter.point((i % SEED_ROWS) + 1) end end,
    concurrent = function() return function(adapter, i) adapter.point((i % SEED_ROWS) + 1) end end,
  },
  {
    name = ('%d-row select'):format(PAGE_SIZE),
    serial = function(adapter) return function() adapter.page(PAGE_SIZE) end end,
    concurrent = function() return function(adapter) adapter.page(PAGE_SIZE) end end,
  },
  {
    name = 'insert',
    serial = function(adapter) return function(i) adapter.insert('bench ' .. i) end end,
    concurrent = function() return function(adapter, i) adapter.insert('bench ' .. i) end end,
  },
  {
    name = 'update',
    serial = function(adapter) return function(i) adapter.update((i % SEED_ROWS) + 1, 'u' .. i) end end,
    concurrent = function() return function(adapter, i) adapter.update((i % SEED_ROWS) + 1, 'u' .. i) end end,
  },
}

local function run_candidate(candidate)
  local adapter = candidate.build()
  local ok, err = adapter.connect()

  if not ok then
    io.write(('  %-28s SKIPPED: %s\n'):format(candidate.id, tostring(err)))
    return
  end

  seed(adapter)
  io.write(('  %-28s null: %s\n'):format(candidate.id, adapter.null()))

  for _, workload in ipairs(WORKLOADS) do
    serial(adapter, workload.name, workload.serial(adapter))
  end

  -- The serial group left the table thousands of rows larger and every seeded
  -- row updated. Comparing the two phases means giving them the same table.
  seed(adapter)
  adapter.close()

  for _, workload in ipairs(WORKLOADS) do
    local done, cerr = concurrent(candidate, workload.name, workload.concurrent())
    if not done then
      io.write(('  %-28s concurrent %s SKIPPED: %s\n'):format(
        candidate.id, workload.name, tostring(cerr)))
    end
  end
end

io.write(('\nophal query-layer bench: %d iterations, %d concurrent, %d seeded rows\n\n')
  :format(ITERATIONS, CONCURRENCY, SEED_ROWS))

for _, candidate in ipairs(drivers.candidates) do
  if ONLY == nil or ONLY == '' or candidate.id:find(ONLY, 1, true) then
    local ok, err = pcall(run_candidate, candidate)
    if not ok then
      io.write(('  %-28s FAILED: %s\n'):format(candidate.id, tostring(err)))
    end
  end
end

io.write('\n')
io.write(('%-28s %-16s %-11s %10s %10s %9s\n'):format(
  'driver', 'workload', 'mode', 'ops/sec', 'seconds', 'failed'))
io.write(('%s\n'):format(('-'):rep(90)))

for _, row in ipairs(report) do
  io.write(('%-28s %-16s %-11s %10.0f %10.3f %9d\n'):format(
    row.candidate, row.workload, row.mode, row.rate, row.seconds, row.failures))
end

io.write('\n')
