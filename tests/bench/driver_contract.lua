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

-- Shaped exactly like `entity.delete`, down to its guard: the table is
-- resolved against the live schema through `connection:table()`, which is the
-- only thing standing between a name from the URL and a DELETE.
registry.define('contract.delete', {
  sql = 'DELETE FROM {table} WHERE id = ?',
  idents = {table = function(value, conn) return conn:table(value) end},
  order = {'table'},
  tables = {'{table:bare}'},
})

--[[ The composed shape, which no other statement here sends.

  `db:composed()` builds a `UNION ALL` with one arm per value and then puts the
  wrapper's `ORDER BY` and `{{limit}}` outside it. That is three dialect
  questions at once -- whether ORDER BY after a UNION may name an output column,
  whether the driver's LIMIT spelling still lands correctly outside the
  parentheses, and whether placeholders numbered across the arms bind in the
  order they are written -- and none of them can be answered by reading the SQL.

  Both arms name the same table on purpose. A second table would test nothing
  further at the SQL level, and what is under test here is the composition
  rather than the schema.
]]
registry.define('contract.union_arm', {
  sql = 'SELECT id, title FROM {table} WHERE title <> ?',
  idents = {table = function(value, conn) return conn:table(value) end},
  order = {'table'},
  tables = {'{table}'},
})

registry.define('contract.union', {
  compose = {arm = 'contract.union_arm', separator = ' UNION ALL '},
  sql = '{{arms}} ORDER BY title{{limit}}',
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

  --[[ The table oracle, which is the resolver `entity.delete` now rests on.

    It has to be exercised against a real `information_schema` on each backend
    rather than against a stub, because what it actually asks is dialect
    specific -- `information_schema` scoped to `CURRENT_SCHEMA()` on PostgreSQL
    and `DATABASE()` on MySQL, and `pragma_table_info` on SQLite -- and "a table
    with no columns is a table that does not exist" is an assumption about all
    three that is worth having a row for.
  ]]
  assert_eq(label .. '_table_finds_a_table',
    conn:table('ophal_contract'), 'ophal_contract')
  assert_eq(label .. '_table_rejects_an_absent_table',
    conn:table('ophal_nonexistent'), nil)

  --[[ Composition, executed rather than inspected.

    Two arms over the two rows, each excluding a different title, so between
    them the union returns both -- and it returns them only if the two bind
    values reach the arms in the order they were written. Arms compiled apart
    and concatenated would each restart at `$1` on PostgreSQL, which is a legal
    *reuse* of the first parameter rather than an error: both arms would exclude
    `alpha` and the answer would come back as two copies of `beta`, silently.
    Reading the titles is what catches that; counting the rows alone would not.
  ]]
  do
    local stmt = conn:composed('contract.union',
      {'ophal_contract', 'ophal_contract'})
    local composed_rows = stmt:run('alpha', 'beta', 0, 10):all(true)

    assert_eq(label .. '_composed_unions_both_arms', #composed_rows, 2)
    assert_eq(label .. '_composed_binds_arms_in_order',
      composed_rows[1].title, 'alpha')
    assert_eq(label .. '_composed_orders_across_the_union',
      composed_rows[2].title, 'beta')

    -- The wrapper's ORDER BY and LIMIT apply to the whole union rather than to
    -- its last arm, which is a question about each dialect's grammar and not
    -- about the layer.
    assert_eq(label .. '_composed_limit_applies_to_the_union',
      #stmt:run('alpha', 'beta', 0, 1):all(true), 1)
  end

  -- An identifier is a compile key, so this is the `'DELETE FROM ' .. type`
  -- shape with the concatenation done once and the name validated.
  conn:with('contract.delete', 'ophal_contract'):run(tonumber(first_id))
  assert_eq(label .. '_identifier_statement_ran',
    tonumber(conn:run('contract.count'):fetch(true).total), 1)

  -- And the refusal, which is the half that matters. A name passing
  -- `^[%a_][%w_]*$` is not thereby a table, and on a real database the schema
  -- is the only thing that knows.
  assert_raises(label .. '_identifier_absent_table_refused', 'rejected identifier',
    function() return conn:with('contract.delete', 'ophal_nonexistent') end)


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
