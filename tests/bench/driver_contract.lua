--[[ The contract every driver has to keep, checked against a real server.

  The unit suite compiles statements and asserts what the SQL says; it never
  connects, because a unit test that needs PostgreSQL is not a unit test. The
  bench connects to everything and never looks at what comes back, because it is
  measuring time. Between the two there was no check that a row could be *read*
  through the layer at all -- and there was a defect sitting in exactly that
  gap: pgmoon and `lua-resty-mysql` hand back a list of rows rather than a
  statement handle, and `includes/database/result.lua` only knew how to pull
  from a handle. Every read on both of the drivers stage 8.3 chose would have
  raised at the first call site stage 8.5 moved.

  So this is the shape of the thing rather than the speed of it: run the layer's
  own operations against each backend and read the answers. Stage 8.6 folds
  these backends into the smoke profiles, which is where this belongs
  permanently; until then it is what stands between a driver and 63 call sites.

    bash tests/bench/setup_backends.sh all   # once
    bash tests/bench/run_driver_contract.sh
]]

package.path = './?.lua;./?/init.lua;' .. package.path

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
    sqlite = {
      driver = 'SQLite3',
      database = os.getenv('OPHAL_BENCH_SQLITE')
        or '/tmp/ophal_contract.sqlite',
    },
  },
  performance = {query_stats = false},
}

local registry = require 'includes.database.registry'
local connection = require 'includes.database.connection'
local request_state = require 'includes.request_state'
require 'includes.database.statements'

local passed, failed = 0, 0

local function ok(name)
  passed = passed + 1
  io.write(('  ok %s\n'):format(name))
end

local function bad(name, detail)
  failed = failed + 1
  io.write(('  FAIL %s: %s\n'):format(name, detail))
end

local function assert_eq(name, actual, expected)
  if actual == expected then
    ok(name)
  else
    bad(name, ('expected %s, got %s'):format(
      tostring(expected), tostring(actual)))
  end
end

local function assert_truthy(name, value)
  assert_eq(name, not not value, true)
end

local function assert_raises(name, needle, fn)
  local raised, err = pcall(fn)

  if raised then
    bad(name, ('expected an error naming %q, got none'):format(needle))
  elseif not tostring(err):find(needle, 1, true) then
    bad(name, ('expected an error naming %q, got: %s'):format(
      needle, tostring(err)))
  else
    ok(name)
  end
end

-- A whole number that `%.14g` cannot hold: 123456789012345 is exact as a double
-- and `tostring()` renders it as 1.2345678901234e+14, which is the defect the
-- layer's own escaper and pgmoon's replacement serializer exist to close.
-- Reading it back is the only proof that either works.
local BIG = 123456789012345

local SCHEMA = {
  lsqlite3 = {
    'DROP TABLE IF EXISTS ophal_contract',
    [[CREATE TABLE ophal_contract(
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      title VARCHAR(255) NOT NULL,
      note VARCHAR(255),
      big BIGINT
    )]],
  },
  -- Kept keyed by driver rather than by connection name, so `sqlite3` meaning a
  -- different binding changes nothing here.
  pgmoon = {
    'DROP TABLE IF EXISTS ophal_contract',
    [[CREATE TABLE ophal_contract(
      id SERIAL PRIMARY KEY,
      title VARCHAR(255) NOT NULL,
      note VARCHAR(255),
      big BIGINT
    )]],
  },
  ['resty-mysql'] = {
    'DROP TABLE IF EXISTS ophal_contract',
    [[CREATE TABLE ophal_contract(
      id INT AUTO_INCREMENT PRIMARY KEY,
      title VARCHAR(255) NOT NULL,
      note VARCHAR(255),
      big BIGINT
    ) ENGINE=InnoDB]],
  },
}

registry.define('contract.insert', {
  sql = 'INSERT INTO ophal_contract(title, note, big) VALUES(?, ?, ?)',
  tables = {'ophal_contract'},
})

registry.define('contract.point', {
  sql = 'SELECT id, title, note, big FROM ophal_contract WHERE id = ?',
  tables = {'ophal_contract'},
})

registry.define('contract.page', {
  sql = 'SELECT id, title FROM ophal_contract ORDER BY id{{limit}}',
  tables = {'ophal_contract'},
})

registry.define('contract.count', {
  sql = 'SELECT COUNT(*) AS total FROM ophal_contract',
  tables = {'ophal_contract'},
})

registry.define('contract.delete', {
  sql = 'DELETE FROM {table} WHERE id = ?',
  idents = {table = true},
  order = {'table'},
  tables = {'{table:bare}'},
})

local function check(name)
  local conn = connection.open(name)
  local label = conn:driver()
  local rs, row, rows, first_id

  io.write(('\n-- %s (%s) --\n'):format(name, label))

  for _, statement in ipairs(SCHEMA[label] or {}) do
    conn:execute(statement)
  end

  -- Two rows, one of them with a NULL note. Three drivers spell a SQL NULL
  -- three ways and only one of them reads as nil without help.
  rs = conn:run('contract.insert', 'alpha', 'first', BIG)

  -- A statement with no result set answers with no rows, on every driver.
  -- pgmoon answers an INSERT with `true` rather than with rows, so this is what
  -- says the driver turned that into the layer's shape rather than handing a
  -- boolean to the wrapper.
  assert_eq(label .. '_insert_has_no_rows', #rs:all(true), 0)

  conn:run('contract.insert', 'beta', nil, nil)

  first_id = conn:last_insert_id('ophal_contract', 'id')
  assert_truthy(label .. '_last_insert_id', tonumber(first_id) ~= nil)

  rs = conn:run('contract.count')
  assert_eq(label .. '_count_by_name', tonumber(rs:fetch(true).total), 2)

  rs = conn:run('contract.point', tonumber(first_id) - 1)
  row = rs:fetch(true)

  assert_eq(label .. '_row_read_by_name', row.title, 'alpha')
  assert_eq(label .. '_note_column_reads', row.note, 'first')

  --[[ Every shipped driver round-trips this, and one of them did not until
    2026-09-08. LuaDBI reads an integer column with 32-bit precision, so this
    value came back as -2045911175 -- bound, written as a literal, or never
    stored at all, since `SELECT 123456789012345` alone is enough. That is why
    SQLite is lsqlite3 now, and this assertion is what says the replacement
    kept its promise. It also covers the layer's own escaper and pgmoon's
    replacement serializer, which exist for the same class of defect one level
    up: reading the value back is the only proof either works.
  ]]
  assert_eq(label .. '_big_integer_round_trips', tonumber(row.big), BIG)

  rs = conn:run('contract.point', tonumber(first_id))
  row = rs:fetch(true)

  assert_eq(label .. '_sql_null_reads_as_nil', row.note, nil)

  rows = conn:run('contract.page', 0, 10):all(true)
  assert_eq(label .. '_paginated_rows', #rows, 2)
  assert_eq(label .. '_paginated_order', rows[1].title, 'alpha')

  -- `{{limit}}` takes (offset, count) in that order on every dialect, which is
  -- the fact that lets one parameter order serve all three.
  rows = conn:run('contract.page', 1, 10):all(true)
  assert_eq(label .. '_offset_skips_the_first', rows[1].title, 'beta')

  assert_raises(label .. '_positional_read_refused', 'named', function()
    return conn:run('contract.count'):fetch()
  end)

  assert_eq(label .. '_field_finds_a_column',
    conn:field('ophal_contract', 'title'), 'title')
  assert_eq(label .. '_field_rejects_an_absent_column',
    conn:field('ophal_contract', 'nonexistent'), nil)

  -- An identifier is a compile key, so this is the `'DELETE FROM ' .. type`
  -- shape with the concatenation done once and the name validated.
  conn:with('contract.delete', 'ophal_contract'):run(tonumber(first_id))
  assert_eq(label .. '_identifier_statement_ran',
    tonumber(conn:run('contract.count'):fetch(true).total), 1)

  --[[ A statement with no result set *of any kind* -- no rows and no affected
    count. pgmoon answers those with `true` rather than with a table, so this is
    what says the driver turned that into the layer's shape instead of handing a
    boolean to the wrapper, where the first read of it would raise.
  ]]
  assert_eq(label .. '_statement_without_a_result_set',
    #conn:run('core.begin'):all(true), 0)
  conn:run('core.rollback')

  -- A transaction is the only way to open one, so what the pool receives is
  -- never inside a transaction.
  conn:transaction(function(db)
    db:run('contract.insert', 'committed', nil, nil)
  end)
  assert_eq(label .. '_transaction_commits',
    tonumber(conn:run('contract.count'):fetch(true).total), 2)

  local function fails_inside_a_transaction()
    conn:transaction(function(db)
      db:run('contract.insert', 'rolled back', nil, nil)
      error('deliberate', 0)
    end)
  end

  assert_raises(label .. '_transaction_propagates_the_error', 'deliberate',
    fails_inside_a_transaction)
  assert_eq(label .. '_transaction_rolls_back',
    tonumber(conn:run('contract.count'):fetch(true).total), 2)

  conn:release(true)

  assert_raises(label .. '_released_connection_refuses_use', 'was released',
    function() return conn:run('contract.count') end)
end

io.write('\nophal driver contract\n')

for _, name in ipairs{'default', 'mysql', 'sqlite'} do
  local ran, err = pcall(check, name)

  if not ran then
    bad(name .. '_backend', tostring(err))
  end
end

-- Two drivers live at once, running one statement name against two dialects.
-- This is the migration and integration case, and it is what `db_set_db_id()`
-- could not express.
do
  request_state.reset()

  local pg = connection.open('default')
  local my = connection.open('mysql')
  local paired = pcall(function()
    assert_eq('parallel_postgresql',
      tonumber(pg:run('contract.count'):fetch(true).total), 2)
    assert_eq('parallel_mysql',
      tonumber(my:run('contract.count'):fetch(true).total), 2)
  end)

  if not paired then
    bad('parallel_drivers', 'one of the two connections failed')
  end

  pg:release(true)
  my:release(true)
end

io.write(('\n%d passed, %d failed\n'):format(passed, failed))

if failed > 0 then
  os.exit(1)
end
