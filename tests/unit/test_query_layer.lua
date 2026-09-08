--[[ The query layer: the resolver, the registry, and the connection object.

  The properties pinned here are the ones the design rests on rather than the
  ones that are easy to assert. Each was shown red before the code that makes it
  green: a connection that can be repointed, an unknown identifier answered with
  the default, an identifier concatenated into SQL unchecked, and a connection
  reused after its request are four different ways for this layer to be worse
  than what it replaces.
]]

package.path = './?.lua;./?/init.lua;' .. package.path

local passed, failed = 0, 0

local function assert_eq(name, actual, expected)
  if actual == expected then
    passed = passed + 1
    io.write(('  ok %s\n'):format(name))
  else
    failed = failed + 1
    io.write(('  FAIL %s: expected %s, got %s\n'):format(
      name, tostring(expected), tostring(actual)))
  end
end

local function assert_truthy(name, value)
  assert_eq(name, not not value, true)
end

-- Asserts that `fn` raises, and that the message names `needle`. A test that
-- only checks "it raised" passes when the code raises for the wrong reason.
local function assert_raises(name, needle, fn, ...)
  local ok, err = pcall(fn, ...)

  if ok then
    failed = failed + 1
    io.write(('  FAIL %s: expected an error naming %q, got none\n'):format(name, needle))
  elseif not tostring(err):find(needle, 1, true) then
    failed = failed + 1
    io.write(('  FAIL %s: expected an error naming %q, got: %s\n'):format(
      name, needle, tostring(err)))
  else
    passed = passed + 1
    io.write(('  ok %s\n'):format(name))
  end
end

_G.settings = {
  db = {
    default = {driver = 'SQLite3', database = ':memory:'},
    legacy = {driver = 'MySQL', database = 'legacy'},
  },
  performance = {query_stats = false},
}

local config = require 'includes.database.config'
local registry = require 'includes.database.registry'
local connection = require 'includes.database.connection'
local router = require 'includes.database.router'
local request_state = require 'includes.request_state'
local stats = require 'includes.database.stats'

io.write '\n-- connection configuration --\n'

do
  local resolved = config.resolve{
    default = {driver = 'SQLite3', database = 'a.db'},
    legacy = {driver = 'resty-mysql', database = 'l'},
  }

  assert_eq('documented_shape_default', resolved.default, 'default')
  assert_eq('documented_shape_driver',
    resolved.connections.default.driver_module, 'lsqlite3')
  assert_eq('second_connection_driver',
    resolved.connections.legacy.driver_module, 'resty_mysql')
  -- The identifier is stamped on the config so a connection failure can name
  -- which connection failed; `db_connect()` logs the database and host and
  -- never the identifier.
  assert_eq('connection_stamped_with_name', resolved.connections.legacy.name, 'legacy')
end

do
  -- `settings.db.default` as a string naming another entry. Both shapes are
  -- legal and both were in use: `db_connect()` reads the first,
  -- `includes/migrate.lua` reads the second, and no test asked them to agree.
  local resolved = config.resolve{
    default = 'primary',
    primary = {driver = 'pgmoon', database = 'p'},
    replica = {driver = 'pgmoon', database = 'r'},
  }

  assert_eq('aliased_default', resolved.default, 'primary')
  assert_truthy('aliased_sibling_present', resolved.connections.replica)
end

assert_raises('alias_to_missing_connection', 'not a connection',
  config.resolve, {default = 'nope'})

-- One hop, never a chain: a string pointing at a string is a configuration
-- error rather than a link to follow.
assert_raises('alias_chain_refused', 'not a connection',
  config.resolve, {default = 'middle', middle = 'primary',
    primary = {driver = 'pgmoon'}})

assert_raises('unknown_driver_fails_at_resolve', 'unknown driver',
  config.resolve, {default = {driver = 'Oracle'}})

assert_raises('driver_required', 'no driver',
  config.resolve, {default = {database = 'x'}})

io.write '\n-- statement compilation --\n'

do
  local pgmoon = require 'includes.database.driver.pgmoon'
  local sqlite = require 'includes.database.driver.lsqlite3'
  local mysql = require 'includes.database.driver.resty_mysql'

  registry.define('test.point', {
    sql = 'SELECT * FROM content WHERE id = ?',
    tables = {'content'},
  })

  assert_eq('numbered_placeholders',
    registry.compile(pgmoon, 'test.point').sql,
    'SELECT * FROM content WHERE id = $1')
  assert_eq('question_placeholders',
    registry.compile(sqlite, 'test.point').sql,
    'SELECT * FROM content WHERE id = ?')

  -- A driver that cannot bind gets a format template instead, decided by
  -- measurement: it beat interleaving literal chunks by 2.7x on one parameter.
  assert_eq('template_for_non_binding_driver',
    registry.compile(mysql, 'test.point').template,
    'SELECT * FROM content WHERE id = %s')

  registry.define('test.page', {
    sql = 'SELECT * FROM content_public ORDER BY created{{limit}}',
    tables = {'content_public'},
  })

  -- The dialects disagree about LIMIT, and both forms take (offset, count) in
  -- that order -- which is why one parameter order serves every dialect.
  assert_eq('limit_macro_postgresql',
    registry.compile(pgmoon, 'test.page').sql,
    'SELECT * FROM content_public ORDER BY created OFFSET $1 LIMIT $2')
  assert_eq('limit_macro_sqlite',
    registry.compile(sqlite, 'test.page').sql,
    'SELECT * FROM content_public ORDER BY created LIMIT ?, ?')

  -- A literal % has to survive into a format template: `LIKE '%foo%'` is
  -- ordinary SQL and `format` would otherwise read it as a conversion.
  registry.define('test.like', {
    sql = "SELECT * FROM content WHERE title LIKE '%draft%' AND id = ?",
    tables = {'content'},
  })
  assert_eq('percent_escaped_in_template',
    registry.compile(mysql, 'test.like').template,
    "SELECT * FROM content WHERE title LIKE '%%draft%%' AND id = %s")

  -- A `?` inside a string literal is data, not a placeholder.
  registry.define('test.quoted', {
    sql = "SELECT * FROM content WHERE title = 'what?' AND id = ?",
    tables = {'content'},
  })
  assert_eq('question_in_literal_is_not_a_placeholder',
    registry.compile(pgmoon, 'test.quoted').nparams, 1)

  assert_raises('undefined_statement', 'is not defined',
    registry.compile, pgmoon, 'test.absent')
end

io.write '\n-- per-dialect overrides --\n'

do
  local pgmoon = require 'includes.database.driver.pgmoon'
  local sqlite = require 'includes.database.driver.lsqlite3'
  local mysql = require 'includes.database.driver.resty_mysql'

  require 'includes.database.statements'

  -- `claim_jobs_sql()` was described as the only statement in the codebase that
  -- is not portable, isolated in a per-driver function. It is now an ordinary
  -- override, and the isolation is the declaration rather than the file.
  assert_truthy('claim_skip_locked_on_postgresql',
    registry.compile(pgmoon, 'jobs.claim').sql:find('SKIP LOCKED', 1, true))
  assert_eq('claim_no_skip_locked_on_sqlite',
    registry.compile(sqlite, 'jobs.claim').sql:find('SKIP LOCKED', 1, true), nil)

  -- PostgreSQL builds a sequence name inside a string literal, where identifier
  -- quotes would produce '"content"_"id"_seq' and no such sequence exists.
  assert_eq('sequence_name_unquoted',
    registry.compile(pgmoon, 'core.last_insert_id',
      {table = 'content', field = 'id'}).sql,
    "SELECT CURRVAL('content_id_seq') AS id")
  -- Every dialect aliases it, because reading the first column positionally is
  -- what a hash-row driver cannot do.
  assert_eq('last_insert_id_sqlite',
    registry.compile(sqlite, 'core.last_insert_id',
      {table = 'content', field = 'id'}).sql,
    'SELECT last_insert_rowid() AS id')

  --[[ `information_schema` spans every schema on a PostgreSQL database and
    every database on a MySQL server, so an unscoped read answers with the
    columns of a same-named table elsewhere on the server. It is `db_field()`
    that answers from this, and `db_field()` is the whitelist `load_by_field`
    interpolates a column name through.
  ]]
  local function schema_read(driver)
    local schema = registry.compile(driver, 'core.table_schema')

    return schema.sql or schema.template
  end

  assert_truthy('schema_read_scoped_on_postgresql',
    schema_read(pgmoon):find('CURRENT_SCHEMA()', 1, true))
  assert_truthy('schema_read_scoped_on_mysql',
    schema_read(mysql):find('DATABASE()', 1, true))
  assert_truthy('schema_read_is_a_pragma_on_sqlite',
    schema_read(sqlite):find('pragma_table_info', 1, true))
end

do
  --[[ A declaration with identifiers and no order for them is broken at every
    use: `order` is what fixes the walk through the compile cache and what makes
    `db:with()`'s values positional. So it is refused at declaration, at load,
    rather than on whichever request reaches that statement first -- the same
    reason an unknown driver name fails at resolve.
  ]]
  assert_raises('idents_need_an_order', 'no order for them',
    registry.define, 'test.unordered',
    {sql = 'DELETE FROM {table}', idents = {table = true}})

  assert_raises('order_names_an_undeclared_ident', 'does not declare',
    registry.define, 'test.misordered',
    {sql = 'DELETE FROM {table}', idents = {table = true},
      order = {'table', 'column'}})

  assert_raises('ident_left_out_of_the_order', 'leaves it out',
    registry.define, 'test.partial',
    {sql = 'DELETE FROM {table} WHERE {column} = ?',
      idents = {table = true, column = true}, order = {'table'}})
end

io.write '\n-- identifiers are compile keys --\n'

do
  local pgmoon = require 'includes.database.driver.pgmoon'
  local mysql = require 'includes.database.driver.resty_mysql'

  registry.define('test.delete', {
    sql = 'DELETE FROM {table} WHERE id = ?',
    idents = {table = true},
    order = {'table'},
    tables = {'{table:bare}'},
  })

  assert_eq('identifier_quoted_for_dialect',
    registry.compile(pgmoon, 'test.delete', {table = 'content'}).sql,
    'DELETE FROM "content" WHERE id = $1')
  assert_eq('identifier_quoted_with_backticks',
    registry.compile(mysql, 'test.delete', {table = 'content'}).template,
    'DELETE FROM `content` WHERE id = %s')

  -- `modules/entity` builds `'DELETE FROM ' .. entity.type` today. The check is
  -- the safety property; the quoting is the correctness one.
  assert_raises('injection_rejected', 'is not an identifier',
    registry.compile, pgmoon, 'test.delete', {table = 'content; DROP TABLE users'})
  assert_raises('quote_in_identifier_rejected', 'is not an identifier',
    registry.compile, pgmoon, 'test.delete', {table = 'content"'})

  -- Attribution follows the identifier, so a statement compiled against a
  -- projection table counts as projection and not as the literal `{table}`.
  assert_eq('attribution_follows_identifier_normalized',
    registry.compile(pgmoon, 'test.delete', {table = 'content'}).bucket,
    'normalized')
  assert_eq('attribution_follows_identifier_projection',
    registry.compile(pgmoon, 'test.delete', {table = 'route_index'}).bucket,
    'projection')
end

io.write '\n-- declared attribution --\n'

do
  local pgmoon = require 'includes.database.driver.pgmoon'

  -- The buckets are ordered: normalized wins over infrastructure, which wins
  -- over projection, so `normalized` stays the count of requests that
  -- reconstructed source data.
  assert_eq('bucket_normalized', stats.bucket{'content'}, 'normalized')
  assert_eq('bucket_projection', stats.bucket{'content_public'}, 'projection')
  assert_eq('bucket_infrastructure', stats.bucket{'ophal_jobs'}, 'infrastructure')
  assert_eq('bucket_mixed_is_normalized',
    stats.bucket{'content_public', 'content'}, 'normalized')
  assert_eq('bucket_no_table', stats.bucket{}, nil)

  --[[ The declared bucket must agree with the parser on the shapes the codebase
    issues. The parser needed a `NOT_A_TABLE` list to survive
    `ON CONFLICT ... DO UPDATE SET`, which once counted every upsert as a
    normalized read; a declaration cannot make that mistake, but it can be
    written wrong, so the two are compared rather than trusted.
  ]]
  local shapes = {
    {'SELECT * FROM content WHERE id = ?', {'content'}},
    {'INSERT INTO projection_version(k) VALUES(?) ON CONFLICT(k) DO UPDATE SET v = 1',
      {'projection_version'}},
    {'UPDATE ophal_jobs SET status = ? WHERE id = ?', {'ophal_jobs'}},
    {'SELECT * FROM content_public JOIN route_index ON 1 = 1', {'content_public', 'route_index'}},
  }

  for i, shape in ipairs(shapes) do
    assert_eq(('declared_matches_parser_%d'):format(i),
      stats.bucket(shape[2]), stats.bucket(stats.tables(shape[1])))
  end

  settings.performance.query_stats = true
  stats.reset()

  local compiled = registry.compile(pgmoon, 'test.point')
  stats.record_bucket(compiled.bucket, compiled.tables)

  local snapshot = stats.snapshot()

  assert_eq('record_bucket_counts_total', snapshot.total, 1)
  assert_eq('record_bucket_counts_normalized', snapshot.normalized, 1)
  assert_eq('record_bucket_counts_table', snapshot.tables.content, 1)

  settings.performance.query_stats = false
  stats.reset()
end

io.write '\n-- the connection object --\n'

do
  local conn = connection.open()

  assert_eq('connection_knows_its_name', conn:name(), 'default')
  assert_eq('connection_knows_its_driver', conn:driver(), 'lsqlite3')
  assert_eq('connection_knows_its_dialect', conn:dialect(), 'sqlite3')

  --[[ The property the whole design turns on. A connection is bound to one
    identifier at construction, so there is no way to point an object that a
    caller is already holding at another database in the middle of something.
  ]]
  assert_raises('connection_cannot_be_repointed', 'bound to',
    function() conn.name = 'legacy' end)
  assert_raises('connection_field_write_refused', 'bound to',
    function() conn._name = 'legacy' end)

  local other = connection.open('legacy')

  assert_eq('second_object_has_its_own_name', other:name(), 'legacy')
  assert_eq('second_object_has_its_own_driver', other:driver(), 'resty-mysql')
  -- Two connections, two drivers, live at the same time. This is the migration
  -- and integration case, and it is what `db_set_db_id()` could not express.
  assert_eq('first_object_unchanged', conn:driver(), 'lsqlite3')
end

assert_raises('unknown_identifier_is_not_the_default', 'no connection named',
  connection.open, 'nonexistent')

do
  --[[ A connection has to be collectable once the request that took it is over,
    and the weak-keyed state table beside it is what allows that. It is easy to
    defeat: Lua 5.1 marks the values of a weak-keyed table strongly and has no
    ephemerons, so an entry whose value can reach its own key is never removed.
    A memoized `with()` statement holding its connection object was exactly that
    shape, and it pinned the connection, its compiled table, its identifier tree
    and its schema cache for the life of the worker -- one per request, on every
    request that deleted an entity or loaded a row by field.
  ]]
  local seen = setmetatable({}, {__mode = 'v'})

  do
    local conn = connection.open()

    seen.conn = conn
    conn:with('test.delete', 'content')
  end

  collectgarbage('collect')
  collectgarbage('collect')

  assert_eq('connection_is_collectable_after_with', seen.conn, nil)
end

-- A statement with identifiers has to be reached through `with()`, and saying
-- so beats indexing a nil `values` inside the compiler.
assert_raises('ident_statement_refuses_a_bare_run', 'db:with', function()
  connection.open():run('test.delete', 1)
end)

io.write '\n-- connection lifetime --\n'

do
  local conn = connection.open()

  conn:release(true)

  -- A released connection must not reconnect. Under keepalive its socket now
  -- belongs to the pool, and reaching it would be cross-request data access --
  -- the database-level form of the bug stage 8.2 closed for `_GET`.
  assert_raises('released_connection_refuses_use', 'was released',
    function() conn:run('test.point', 1) end)
end

do
  -- A connection stashed in an upvalue and reused next request. The stamp is
  -- what catches it when release did not run.
  local conn = connection.open()

  request_state.reset()

  assert_raises('stale_connection_refuses_use', 'belongs to another request',
    function() conn:run('test.point', 1) end)
end

io.write '\n-- the router --\n'

do
  request_state.reset()

  local a = router.get()
  local b = router.get()

  assert_eq('router_memoizes_per_request', a, b)

  -- `db_connection()` and `db_connection('default')` name one connection, so
  -- they must not open two sockets to it.
  assert_eq('router_default_and_name_are_one_object', a, router.get('default'))

  local legacy = router.get('legacy')

  assert_truthy('router_returns_distinct_objects', legacy ~= a)
  assert_eq('router_released_all', router.release_all(true), 2)

  request_state.reset()

  assert_truthy('router_fresh_object_next_request', router.get() ~= a)
end

do
  request_state.reset()
  config.reset()

  local saved = settings.db

  settings.db = {other = {driver = 'SQLite3', database = 'x'}}

  assert_raises('no_default_configured', 'no default connection',
    router.get)

  settings.db = saved
  config.reset()
  request_state.reset()
end

io.write(('\n%d passed, %d failed\n'):format(passed, failed))

if failed > 0 then
  os.exit(1)
end
