--[[ What the query layer costs, against calling the driver directly.

  Stage 8.3 chose the drivers. This asks the separate question the plan gates
  8.4 on: how much of that throughput the abstraction gives back. The layer only
  earns its place if the answer is small, and "small" has to be a number rather
  than a claim, so every part of it is timed apart from the others:

  - **layer vs direct** on a real query, serial and concurrent. This is the
    number that decides the gate, and the point of it is that a query is tens of
    microseconds while the layer is nanoseconds -- so it should be invisible.
  - **the lookup in isolation**, with no database at all, because a difference
    buried under a round trip is worth measuring on its own before believing it
    is zero.
  - **the chunked escape** against building the same SQL with `..`, which is
    what a MySQL driver has to do since `lua-resty-mysql` cannot bind.
  - **declared attribution against the tokenizer**, with `query_stats` on. This
    is the one that changes what the project can afford: the counters are off by
    default because the parser is not free.
  - **the NULL normalisation pass**, which is per column rather than per query,
    so it is timed on a 100-row select where it actually costs something.
]]

package.path = './?.lua;./?/init.lua;' .. package.path

local ITERATIONS = tonumber(os.getenv('OPHAL_BENCH_ITERATIONS') or '') or 5000
local CONCURRENCY = tonumber(os.getenv('OPHAL_BENCH_CONCURRENCY') or '') or 50
local MICRO = tonumber(os.getenv('OPHAL_BENCH_MICRO') or '') or 2000000
local SEED_ROWS = tonumber(os.getenv('OPHAL_BENCH_ROWS') or '') or 2000
local PAGE_SIZE = 100

-- The lab's servers, from `tests/bench/setup_backends.sh`.
settings = {
  db = {
    default = {
      driver = 'pgmoon',
      database = 'ophal_bench',
      username = 'ophal',
      password = 'ophal',
      host = '127.0.0.1',
      port = 15432,
    },
    mysql = {
      driver = 'resty-mysql',
      database = 'ophal_bench',
      username = 'ophal',
      password = 'ophal',
      host = '127.0.0.1',
      port = 13306,
    },
  },
  performance = {query_stats = false},
}

local config = require 'includes.database.config'
local registry = require 'includes.database.registry'
local router = require 'includes.database.router'
local connection = require 'includes.database.connection'
local stats = require 'includes.database.stats'
local db_result = require 'includes.database.result'
require 'includes.database.statements'

registry.define('bench.point', {
  sql = 'SELECT id, title, note FROM bench_rows WHERE id = ?',
  tables = {'bench_rows'},
})

-- Five parameters, the shape the codebase's UPDATE statements actually have.
registry.define('bench.wide', {
  sql = [[UPDATE bench_rows SET title = ?, note = ? WHERE id = ? AND title <> ? AND id > ?]],
  tables = {'bench_rows'},
})

registry.define('bench.page', {
  sql = 'SELECT id, title, note FROM bench_rows ORDER BY id{{limit}}',
  tables = {'bench_rows'},
})

local function now()
  ngx.update_time()
  return ngx.now()
end

--[[ `ngx.now()` has millisecond resolution, which is fine for a phase that
  makes thousands of round trips and useless for one that measures a table
  lookup. `os.clock()` is CPU time at microsecond resolution, which is the right
  instrument for the in-process costs and the wrong one for anything that waits
  on a socket -- so each phase uses the clock that matches what it measures.
]]
local function cpu()
  return os.clock()
end

--[[ Somewhere for results to go.

  LuaJIT removes a loop whose result is never used, and it is very good at it:
  the first version of this file reported the compiled-statement lookup at
  0.5 ns/op, which is not a fast lookup but an absent one. Everything measured
  in the micro phases is accumulated here so the work cannot be eliminated.
]]
local sink = 0

local function consume(value)
  local kind = type(value)

  -- Touching the content, not merely testing for nil: LuaJIT can prove a string
  -- result is always truthy and eliminate the call that produced it, which is
  -- how an earlier run of this file reported `string.format` at 3 ns.
  if kind == 'string' then
    sink = sink + #value
  elseif kind == 'table' then
    sink = sink + 1
  elseif value ~= nil then
    sink = sink + 1
  end
end

local report = {}

local function record(group, label, ops, seconds, note)
  report[#report + 1] = {
    group = group,
    label = label,
    ops = ops,
    seconds = seconds,
    rate = seconds > 0 and ops / seconds or 0,
    note = note,
  }
end

local function timed(group, label, iterations, fn, note)
  local started = now()

  for i = 1, iterations do
    fn(i)
  end

  record(group, label, iterations, now() - started, note)
end

-- The same, on the CPU clock, for phases that never touch a socket.
local function timed_micro(group, label, iterations, fn, note)
  local started = cpu()

  for i = 1, iterations do
    fn(i)
  end

  record(group, label, iterations, cpu() - started, note)
end

-- ------------------------------------------------------------- fixtures ----

local SCHEMA = {
  pgmoon = {
    'DROP TABLE IF EXISTS bench_rows',
    [[CREATE TABLE bench_rows(
      id SERIAL PRIMARY KEY,
      title VARCHAR(255) NOT NULL,
      note VARCHAR(255)
    )]],
  },
  ['resty-mysql'] = {
    'DROP TABLE IF EXISTS bench_rows',
    [[CREATE TABLE bench_rows(
      id INT AUTO_INCREMENT PRIMARY KEY,
      title VARCHAR(255) NOT NULL,
      note VARCHAR(255)
    ) ENGINE=InnoDB]],
  },
}

local function seed(conn)
  for _, statement in ipairs(SCHEMA[conn:driver()]) do
    conn:execute(statement)
  end

  -- Half the rows have a NULL note, so the normalisation pass has something to
  -- normalise and the driver's NULL shape is exercised rather than assumed.
  for i = 1, SEED_ROWS do
    conn:execute('INSERT INTO bench_rows(title, note) VALUES(?, ?)',
      'row ' .. i, i % 2 == 0 and ('note ' .. i) or nil)
  end
end

-- ------------------------------------------------------- layer vs direct ----

--[[ The same query, three ways.

  `direct` is what stage 8.3 measured: the driver called with SQL it already
  holds, which is the ceiling. `layer` goes through `db:run()` -- a hash lookup
  for the compiled statement, an accounting increment, the driver call. `ad hoc`
  is `db:execute()`, which splits and renders the SQL every time, and is here to
  show what the compile cache is worth rather than as a candidate.
]]
local function compare_direct(conn, driver, label)
  local compiled = registry.compile(driver, 'bench.point')
  local handle = conn:handle()

  timed('query: ' .. label, 'direct driver call', ITERATIONS, function(i)
    local res, err = driver.execute(handle, compiled, (i % SEED_ROWS) + 1)
    if res == nil then error(tostring(err)) end
  end)

  timed('query: ' .. label, 'layer db:run()', ITERATIONS, function(i)
    conn:run('bench.point', (i % SEED_ROWS) + 1)
  end)

  timed('query: ' .. label, 'layer, stats on', ITERATIONS, function(i)
    stats.reset()
    settings.performance.query_stats = true
    conn:run('bench.point', (i % SEED_ROWS) + 1)
  end)

  settings.performance.query_stats = false
  stats.reset()

  timed('query: ' .. label, 'ad hoc db:execute()', ITERATIONS, function(i)
    conn:execute('SELECT id, title, note FROM bench_rows WHERE id = ?', (i % SEED_ROWS) + 1)
  end)
end

--[[ Concurrency, which is the only mode that describes a worker.

  One connection object per thread, built directly rather than through
  `router.get()`. That is not a workaround -- it is the model being correct.
  `ngx.ctx` belongs to a *request*, and light threads spawned inside one share
  it, so fifty threads asking the router for a connection correctly get the same
  object fifty times. A worker serving fifty concurrent requests has fifty
  contexts and fifty connections, and that is what this reproduces.

  The first version of this file did call `router.get()` per thread, and the
  result was one connection shared by fifty threads with the first to finish
  releasing it under the others: forty-nine failed instantly and the phase
  reported a hundred operations as if they were five thousand.
]]
local function compare_concurrent(name, label)
  local per_thread = math.floor(ITERATIONS / CONCURRENCY)

  local function run_phase(phase_label, make)
    local threads, conns, completed = {}, {}, {}
    local started, elapsed, total, failures, last_error = 0, 0, nil

    for index = 1, CONCURRENCY do
      conns[index] = connection.open(name)
      completed[index] = 0
    end

    --[[ Connect every socket before the clock starts.

      Otherwise the first phase to run pays for fifty TCP connects and fifty
      authentication handshakes while the second finds them waiting in the
      keepalive pool its predecessor filled -- worth about 8 us an operation
      spread over five thousand of them, which is four hundred times the thing
      being measured. The first version of this file reported the layer 24%
      slower than the driver it calls for exactly that reason, and the ordering
      was the whole difference.
    ]]
    for index = 1, CONCURRENCY do
      conns[index]:handle()
    end

    started = now()

    for index = 1, CONCURRENCY do
      threads[index] = ngx.thread.spawn(function()
        local conn = conns[index]
        local fn = make(conn)
        local first = (index - 1) * per_thread

        for offset = 1, per_thread do
          local ok, err = pcall(fn, first + offset)
          if not ok then return nil, err end
          completed[index] = completed[index] + 1
        end

        return true
      end)
    end

    total, failures = 0, 0

    for index, thread in ipairs(threads) do
      local ok, res, err = ngx.thread.wait(thread)

      if not ok or res == nil then
        failures = failures + (per_thread - completed[index])
        last_error = err or res
      end

      total = total + completed[index]
    end

    elapsed = now() - started

    for _, conn in ipairs(conns) do
      pcall(conn.release, conn, true)
    end

    record('concurrent: ' .. label, phase_label, total, elapsed,
      failures > 0 and ('%d failed: %s'):format(failures, tostring(last_error)) or nil)
  end

  run_phase('layer db:run()', function(conn)
    return function(i) conn:run('bench.point', (i % SEED_ROWS) + 1) end
  end)

  run_phase('direct driver call', function(conn)
    local driver = require('includes.database.driver.'
      .. config.get(name).driver_module)
    local compiled = registry.compile(driver, 'bench.point')
    local handle = conn:handle()

    return function(i)
      local res, err = driver.execute(handle, compiled, (i % SEED_ROWS) + 1)
      if res == nil then error(tostring(err)) end
    end
  end)
end

-- ---------------------------------------------------------- micro costs ----

local function micro(conn, driver, label)
  local compiled = registry.compile(driver, 'bench.point')
  local name = label == 'postgresql' and nil or 'mysql'
  -- Several names, indexed by the loop counter. A single constant key is
  -- loop-invariant and LuaJIT hoists the lookup clean out of the loop, which
  -- reports 0.6 ns and measures nothing.
  local names = {'bench.point', 'bench.page', 'bench.wide', 'jobs.claim'}
  local cache = {}

  for _, statement in ipairs(names) do
    cache[statement] = registry.compile(driver, statement)
  end

  -- What `db:run()` adds before the driver is reached, with no socket in the
  -- way. If this is not tiny then nothing further matters.
  timed_micro('lookup: ' .. label, 'compiled statement lookup', MICRO, function(i)
    consume(cache[names[(i % 4) + 1]])
  end)

  timed_micro('lookup: ' .. label, 'registry.compile() cached', MICRO, function(i)
    consume(registry.compile(driver, names[(i % 4) + 1]))
  end)

  timed_micro('lookup: ' .. label, 'router.get() memoized', MICRO, function()
    consume(router.get(name))
  end)

  do
    -- The layer wraps every result in `includes/database/result.lua`, which the
    -- direct call does not. That is an allocation per query, so it is the one
    -- part of `db:run()` whose cost is not a lookup.
    local rows = {{id = 1, title = 'a'}, {id = 2, title = 'b'}}

    timed_micro('lookup: ' .. label, 'db_result.wrap()', MICRO, function()
      consume(db_result.wrap(rows))
    end)
  end

  settings.performance.query_stats = true
  stats.reset()

  timed_micro('accounting', 'declared: record_bucket()', MICRO, function()
    stats.record_bucket(compiled.bucket, compiled.tables)
  end)

  timed_micro('accounting', 'parsed: record() tokenizer', MICRO, function()
    stats.record('SELECT id, title, note FROM bench_rows WHERE id = ?')
  end)

  settings.performance.query_stats = false
  stats.reset()
end

--[[ The escape path a non-binding driver has to take.

  `lua-resty-mysql` 0.27 has no prepare, so the layer builds the SQL. The
  question is whether cutting the statement at compile time is worth it against
  the obvious alternative of formatting the whole string per call.
]]
local function escape_costs()
  local driver = require 'includes.database.driver.resty_mysql'
  local one = registry.compile(driver, 'bench.point')
  local many = registry.compile(driver, 'bench.wide')

  timed_micro('escape, 1 param (mysql)', 'format template', MICRO, function(i)
    consume(driver.assemble(one, i))
  end)

  timed_micro('escape, 1 param (mysql)', 'chunk concat', MICRO, function(i)
    consume(driver.assemble_wide(one, i))
  end)

  -- Five parameters is nearer what the codebase actually issues -- the content
  -- and user updates name six including the id. One parameter is the case that
  -- flatters formatting, so measuring only it would be measuring the easy half.
  timed_micro('escape, 5 params (mysql)', 'format template', MICRO, function(i)
    consume(driver.assemble(many, i, 'a', i, 'b', i))
  end)

  timed_micro('escape, 5 params (mysql)', 'chunk concat', MICRO, function(i)
    consume(driver.assemble_wide(many, i, 'a', i, 'b', i))
  end)
end

--[[ Normalising NULL, which costs per column rather than per query.

  `lua-resty-mysql` returns `ngx.null`, which is neither nil nor `empty()`, so
  every call site in the codebase would have to learn about it if the driver did
  not. This is the price of not doing that, on a page of rows rather than on one.
]]
local function null_costs(conn, driver)
  local rows = conn:run('bench.page', 0, PAGE_SIZE):raw()
  local passes = 20000

  timed_micro('null normalise', ('%s, %d rows'):format(driver.name, PAGE_SIZE),
    passes, function()
      consume(driver.rows(rows))
    end, 'per pass over a page')
end

-- ---------------------------------------------------------------- report ----

local function print_report()
  local group

  io.write(('\nophal query-layer overhead: %d queries, %d concurrent, %d micro iterations, %d rows\n\n')
    :format(ITERATIONS, CONCURRENCY, MICRO, SEED_ROWS))

  io.write(('%-26s %-28s %12s %10s %12s\n')
    :format('group', 'variant', 'ops/sec', 'seconds', 'ns/op'))
  io.write(('%s\n'):format(('-'):rep(92)))

  for _, row in ipairs(report) do
    if row.group ~= group then
      group = row.group
      io.write(('%s\n'):format(group))
    end

    io.write(('%-26s %-28s %12d %10.3f %12.1f  %s\n'):format(
      '', row.label, row.rate, row.seconds,
      row.ops > 0 and (row.seconds / row.ops) * 1e9 or 0, row.note or ''))
  end

  io.write('\n')
end

-- ------------------------------------------------------------------ main ----

local function main()
  local pg = router.get()
  local pg_driver = require 'includes.database.driver.pgmoon'

  seed(pg)
  compare_direct(pg, pg_driver, 'postgresql')
  micro(pg, pg_driver, 'postgresql')
  null_costs(pg, pg_driver)
  pg:release(true)

  local my = router.get 'mysql'
  local my_driver = require 'includes.database.driver.resty_mysql'

  seed(my)
  compare_direct(my, my_driver, 'mysql')
  null_costs(my, my_driver)
  my:release(true)

  escape_costs()

  router.release_all(true)

  compare_concurrent(nil, 'postgresql')
  compare_concurrent('mysql', 'mysql')

  print_report()
end

local ok, err = pcall(main)

if not ok then
  io.write(('\nbench failed: %s\n'):format(tostring(err)))
  print_report()
  os.exit(1)
end
