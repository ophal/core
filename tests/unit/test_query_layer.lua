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
    -- The values below are written in this test, so `trusted` is the honest
    -- guard: what these assertions are about is the shape check and the
    -- quoting, which every identifier gets whatever resolved it.
    idents = {table = registry.trusted},
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

io.write '\n-- variadic statements --\n'

--[[ `?*` is what lets a statement whose *width* is not known until it runs be
  declared rather than assembled. The permission read was the last value
  interpolation in the codebase and it was injectable; this is the mechanism
  that removes the reason for it.
]]
do
  local pgmoon = require 'includes.database.driver.pgmoon'
  local sqlite = require 'includes.database.driver.lsqlite3'
  local mysql = require 'includes.database.driver.resty_mysql'

  registry.define('test.in_list', {
    sql = 'SELECT permission FROM role_permission WHERE role_id IN (?*)',
    tables = {'role_permission'},
  })

  assert_eq('variadic_detected_at_define',
    registry.declaration('test.in_list').variadic, true)
  assert_eq('fixed_statement_is_not_variadic',
    registry.declaration('test.point').variadic, false)

  -- One placeholder per value, comma separated, in every placeholder style.
  assert_eq('variadic_one_value_question',
    registry.compile(sqlite, 'test.in_list', nil, nil, 1).sql,
    'SELECT permission FROM role_permission WHERE role_id IN (?)')
  assert_eq('variadic_three_values_question',
    registry.compile(sqlite, 'test.in_list', nil, nil, 3).sql,
    'SELECT permission FROM role_permission WHERE role_id IN (?, ?, ?)')
  assert_eq('variadic_numbered_renumbers',
    registry.compile(pgmoon, 'test.in_list', nil, nil, 3).sql,
    'SELECT permission FROM role_permission WHERE role_id IN ($1, $2, $3)')
  assert_eq('variadic_template_for_non_binding',
    registry.compile(mysql, 'test.in_list', nil, nil, 2).template,
    'SELECT permission FROM role_permission WHERE role_id IN (%s, %s)')

  -- The arity reaches the driver, which is what decides how many values are
  -- bound or escaped. A wrong count here is a silent wrong answer.
  assert_eq('variadic_nparams_follows_arity',
    registry.compile(sqlite, 'test.in_list', nil, nil, 4).nparams, 4)

  -- Each width is compiled once and cached under its own key, so a second call
  -- at the same width is a lookup and a different width is not a collision.
  assert_truthy('variadic_same_width_is_cached',
    registry.compile(sqlite, 'test.in_list', nil, nil, 3)
      == registry.compile(sqlite, 'test.in_list', nil, nil, 3))
  assert_eq('variadic_widths_do_not_collide',
    registry.compile(sqlite, 'test.in_list', nil, nil, 2)
      == registry.compile(sqlite, 'test.in_list', nil, nil, 3), false)

  --[[ Both directions are refused, and each for its own reason.

    A variadic statement reached without an arity would render one placeholder
    and bind however many the caller passed -- a wrong answer rather than an
    error. A fixed statement reached with one means the caller believes it takes
    a list, and it does not.

    Zero is refused rather than rendered: `IN ()` is a syntax error everywhere,
    and "no values" is a question about the caller's intent -- no roles means no
    permissions, which is a branch and not a query.
  ]]
  assert_raises('variadic_without_arity_refused', 'reach it with db:list',
    registry.compile, sqlite, 'test.in_list')
  assert_raises('fixed_with_arity_refused', 'takes no list',
    registry.compile, sqlite, 'test.point', nil, nil, 2)
  assert_raises('variadic_empty_list_refused', 'empty list',
    registry.compile, sqlite, 'test.in_list', nil, nil, 0)

  -- A `?*` that is variadic on one dialect and not on another would take
  -- `db:list()` on one backend and refuse it on the other, which would only
  -- surface on whichever backend the suite does not run.
  assert_raises('variadic_must_agree_across_dialects', 'in both or neither',
    registry.define, 'test.in_list_split', {
      sql = 'SELECT 1 FROM t WHERE a IN (?*)',
      postgresql = {sql = 'SELECT 1 FROM t WHERE a = ?'},
      tables = {'t'},
    })
end

io.write '\n-- every identifier names its guard --\n'

--[[ `idents = {table = true}` used to mean "the shape check alone".

  It read identically to a resolved identifier, so whether a given declaration
  had one guard or two could only be answered by reading all six of them. Three
  did: `load_by_field` in `modules/user`, `modules/file` and `modules/comment`
  resolve a column through `connection:field()`. Three did not.

  The rule is what closes that, rather than the three fixes: a non-function
  entry is refused at load, so every identifier in the codebase names the guard
  it rests on, and `grep trusted` enumerates the single-guard ones for good.
]]
do
  local pgmoon = require 'includes.database.driver.pgmoon'

  assert_raises('idents_true_is_refused', 'needs a resolver', registry.define,
    'test.guardless', {
      sql = 'DELETE FROM {table} WHERE id = ?',
      idents = {table = true},
      order = {'table'},
      tables = {'{table}'},
    })

  -- Not only `true`: anything that cannot be called is refused, so a plausible
  -- looking table of allowed names is not a way around it either.
  assert_raises('idents_table_is_refused', 'needs a resolver', registry.define,
    'test.guardless_list', {
      sql = 'DELETE FROM {table} WHERE id = ?',
      idents = {table = {'content', 'page'}},
      order = {'table'},
      tables = {'{table}'},
    })

  -- The message has to say what to write instead, because the reader hitting it
  -- is adding a declaration and the choice between the two kinds is the whole
  -- decision being forced.
  assert_raises('resolver_message_names_the_schema_lookup', 'connection:table()',
    registry.define, 'test.guardless_message', {
      sql = 'DELETE FROM {table} WHERE id = ?',
      idents = {table = true},
      order = {'table'},
      tables = {'{table}'},
    })
  assert_raises('resolver_message_names_trusted', 'registry.trusted',
    registry.define, 'test.guardless_message_two', {
      sql = 'DELETE FROM {table} WHERE id = ?',
      idents = {table = true},
      order = {'table'},
      tables = {'{table}'},
    })

  --[[ `trusted` asserts provenance and validates nothing, so the shape check
    behind it has to still be the thing that stops a hostile value. If this ever
    goes green-by-omission, `trusted` has quietly become a bypass.
  ]]
  assert_raises('trusted_still_takes_the_shape_check', 'is not an identifier',
    registry.compile, pgmoon, 'test.delete', {table = 'users; DROP TABLE x'})
end

--[[ The resolver path itself, which had no unit coverage at all.

  Everything above pins what the registry does with an identifier once it has
  one. What was never asserted is that the declared resolver is consulted, gets
  the connection to answer from, and that its refusal stops the compile -- which
  is the entire security property of the three `load_by_field` declarations.
]]
do
  local pgmoon = require 'includes.database.driver.pgmoon'
  local seen_value, seen_connection
  local fake = {}

  function fake:table(name)
    return name == 'content' and name or nil
  end

  registry.define('test.resolved', {
    sql = 'DELETE FROM {table} WHERE id = ?',
    idents = {
      table = function(value, conn)
        seen_value, seen_connection = value, conn
        return conn:table(value)
      end,
    },
    order = {'table'},
    tables = {'{table}'},
  })

  assert_eq('resolver_accepts_a_table_the_schema_has',
    registry.compile(pgmoon, 'test.resolved', {table = 'content'}, fake).sql,
    'DELETE FROM "content" WHERE id = $1')
  assert_eq('resolver_receives_the_value', seen_value, 'content')
  assert_eq('resolver_receives_the_connection', seen_connection, fake)

  -- The absent table is the case that matters: a name passing `^[%a_][%w_]*$`
  -- is not thereby a table, and the schema is the only thing that knows.
  assert_raises('resolver_refusal_stops_the_compile', 'rejected identifier',
    registry.compile, pgmoon, 'test.resolved', {table = 'pg_shadow'}, fake)
  assert_raises('resolver_refusal_names_the_value', 'pg_shadow',
    registry.compile, pgmoon, 'test.resolved', {table = 'pg_shadow'}, fake)
end

--[[ The two declarations this rule was written for, driven directly.

  `entity.delete` and `entity.delete_relation` take their table from
  `entity/delete/<type>/<id>` in the URL. `modules/entity` checks it against the
  registered entity types before calling, and that check is correctly the
  module's -- but the declaration could not see it, so it now states its own.
]]
do
  local pgmoon = require 'includes.database.driver.pgmoon'
  local fake = {}

  require 'modules.entity.statements'

  function fake:table(name)
    return (name == 'content' or name == 'tag') and name or nil
  end

  assert_eq('entity_delete_accepts_a_real_table',
    registry.compile(pgmoon, 'entity.delete', {table = 'content'}, fake).sql,
    'DELETE FROM "content" WHERE id = $1')

  assert_raises('entity_delete_rejects_an_absent_table', 'rejected identifier',
    registry.compile, pgmoon, 'entity.delete', {table = 'users'}, fake)

  -- The bare path is the one with no quoting behind it, so it is the one whose
  -- guard has to hold on its own.
  assert_eq('entity_delete_relation_composes_the_name',
    registry.compile(pgmoon, 'entity.delete_relation',
      {table = 'content', parent = 'tag'}, fake).sql,
    'DELETE FROM rel_content_tag WHERE content_id = $1')

  assert_raises('entity_delete_relation_rejects_an_absent_parent',
    'rejected identifier', registry.compile, pgmoon, 'entity.delete_relation',
    {table = 'content', parent = 'users'}, fake)
end

--[[ A resolver may block, so it cannot run inside the text pass.

  This is stage 8.7's PostgreSQL profile in miniature, and it needs no database.
  A resolver is a schema lookup, and `connection:table()` reads
  `core.table_schema` the first time it is asked about a table -- which on a
  cosocket driver *yields*. Resolvers used to be called from inside
  `substitute()`'s `gsub` replacement function, and neither LuaJIT nor PUC Lua
  can yield out of one: the compile raised `attempt to yield across C-call
  boundary`, from a line mentioning no socket and no coroutine.

  SQLite has no socket, so it could not happen there, and SQLite was the only
  backend anything ran against -- which made every identifier statement in the
  codebase broken on PostgreSQL and MySQL and green on the one that could not
  show it: the three `load_by_field`, both `entity.delete*`, and
  `tag.legacy_arm`.

  Driving it through a coroutine is what turns "yields" into something a unit
  test can assert. The resolver yields once; the compile has to survive that and
  finish.
]]
do
  local pgmoon = require 'includes.database.driver.pgmoon'
  local calls = 0
  local fake = {}

  function fake:table(name)
    return name == 'content' and name or nil
  end

  registry.define('test.blocking_resolver', {
    -- The identifier appears three times, twice bare, once quoted -- the shape
    -- of `tag.legacy_arm`, which is the declaration that reaches a real schema
    -- lookup on the tag listing's fallback.
    sql = [[SELECT '{table:bare}' kind FROM {table} WHERE {table:bare}_id = ?]],
    idents = {
      table = function(value, conn)
        calls = calls + 1
        coroutine.yield('resolving')

        return conn:table(value)
      end,
    },
    order = {'table'},
    tables = {'{table}'},
  })

  local co = coroutine.create(function()
    return registry.compile(
      pgmoon, 'test.blocking_resolver', {table = 'content'}, fake)
  end)

  local resumed, yielded = coroutine.resume(co)

  assert_eq('resolver_may_block', resumed and yielded, 'resolving')

  local finished, compiled = coroutine.resume(co)

  assert_eq('compile_survives_a_blocking_resolver', finished and compiled.sql,
    [[SELECT 'content' kind FROM "content" WHERE content_id = $1]])

  --[[ Once, not once per slot and not once per table name.

    That is the same property from the other side: resolution happens ahead of
    every text pass, so the number of times a declaration mentions an identifier
    cannot change how often the database is asked about it. Under the old shape
    this statement resolved four times -- three slots and one `tables` entry --
    and each one of them was a schema read that could block.
  ]]
  assert_eq('resolver_runs_once_per_compile', calls, 1)
  assert_eq('resolved_statement_attributes_to_the_real_table',
    compiled.tables[1], 'content')
end

io.write '\n-- releasing a connection --\n'

--[[ Pooling is a cosocket facility, and the test for it is the socket.

  `handle.keepalive` is defined whatever socket pgmoon is on, so a driver
  guarding on the method asks a LuaSocket connection to pool itself -- and
  pgmoon's LuaSocket backend *raises* from `setkeepalive` rather than declining
  it. That runtime is the `ophal` CLI, the installer and `ophal migrate apply`,
  so every PostgreSQL connection released there errored after its work had
  already committed. `router.release_all()` wraps each release in `pcall`, which
  is why it never surfaced: the connection was simply never closed either.

  Stage 8.7's seeder is what ran it, being the first thing to release a
  PostgreSQL connection by hand rather than through the request teardown.
]]
do
  local pgmoon = require 'includes.database.driver.pgmoon'
  local pooled, closed

  local function handle(sock_type)
    pooled, closed = false, false

    return {
      sock_type = sock_type,
      keepalive = function() pooled = true return true end,
      disconnect = function() closed = true end,
    }
  end

  assert_eq('cosocket_release_pools', pgmoon.release(handle('nginx'), true), true)
  assert_eq('cosocket_release_did_not_close', closed, false)

  assert_eq('luasocket_release_closes',
    pgmoon.release(handle('luasocket'), true), false)
  assert_eq('luasocket_release_did_not_pool', pooled, false)
  assert_eq('luasocket_release_closed_it', closed, true)

  -- A failed connection is closed on either socket: it may hold a live
  -- transaction or unread protocol traffic, so it never goes back to a pool.
  assert_eq('failed_release_closes', pgmoon.release(handle('nginx'), false), false)
  assert_eq('failed_release_did_not_pool', pooled, false)
end

io.write '\n-- composed statements --\n'

--[[ A statement whose *structure* is decided by the caller.

  `run()` covers a fixed statement and `list()` a fixed one of varying width.
  This is the third and last shape: a UNION with one arm per entity type a tag
  is attached to, which is why `modules/tag` was the last holder of SQL text in
  application code.

  The property everything else rests on is that arms are composed as body text
  *before* placeholders are split, so numbering runs across the whole statement
  instead of restarting at each arm. `composed_numbers_across_the_arms` is the
  assertion that says so, and it is the one that would fail if someone
  "simplified" this into joining compiled arms.
]]
do
  local pgmoon = require 'includes.database.driver.pgmoon'
  local lsqlite = require 'includes.database.driver.lsqlite3'
  local fake = {}

  function fake:table(name)
    return (name == 'content' or name == 'page') and name or nil
  end

  registry.define('test.arm', {
    sql = "SELECT '{type:bare}' type, e.id FROM {type} e WHERE e.tag_id = ?",
    idents = {type = function(value, conn) return conn:table(value) end},
    order = {'type'},
    tables = {'{type}', 'field_tag'},
  })

  registry.define('test.union', {
    compose = {arm = 'test.arm', separator = ' UNION ALL '},
    sql = '{{arms}} ORDER BY id{{limit}}',
  })

  local two = registry.compile(pgmoon, 'test.union', nil, fake, nil,
    {'content', 'page'})

  assert_truthy('composed_joins_the_arms', two.sql:find('UNION ALL', 1, true))
  assert_truthy('composed_quotes_each_arm_table', two.sql:find('"page"', 1, true))
  assert_truthy('composed_renders_the_bare_literal',
    two.sql:find("'page' type", 1, true))

  --[[ Numbering across the arms, not within them.

    Two arms and a `{{limit}}` is four parameters: `$1` and `$2` are the arms'
    tag ids and `$3`/`$4` the offset and count. Arms compiled separately and
    concatenated would each start at `$1`, which PostgreSQL accepts as a
    *reuse* of the first parameter -- so this would not error, it would return
    the wrong rows.
  ]]
  assert_eq('composed_numbers_across_the_arms', two.nparams, 4)
  assert_truthy('composed_first_arm_is_dollar_one', two.sql:find('$1', 1, true))
  assert_truthy('composed_second_arm_is_dollar_two', two.sql:find('$2', 1, true))
  assert_truthy('composed_limit_params_follow_the_arms',
    two.sql:find('OFFSET $3 LIMIT $4', 1, true))

  -- The wrapper's macro is still the driver's, so the dialect fragment does not
  -- leak into the composition.
  assert_truthy('composed_limit_is_the_dialect_spelling',
    registry.compile(lsqlite, 'test.union', nil, fake, nil, {'content'})
      .sql:find('LIMIT ?, ?', 1, true))

  -- Attribution is the union of the arms' tables, so a listing over two types
  -- counts as two normalized reads rather than as the literal `{type}`.
  assert_eq('composed_attribution_unions_arm_tables', #two.tables, 3)
  assert_eq('composed_attribution_bucket', two.bucket, 'normalized')

  -- The arm tuple is the cache key, so a different tuple is a different
  -- statement rather than a prefix hit on the first.
  assert_eq('composed_one_arm_is_a_distinct_compile',
    registry.compile(pgmoon, 'test.union', nil, fake, nil, {'content'}).nparams,
    3)

  -- The arm's resolver still runs: the entity type comes from a `field_tag`
  -- row, so the schema is what says whether it may name a table.
  assert_raises('composed_arm_resolver_refuses_an_absent_table',
    'rejected identifier', registry.compile, pgmoon, 'test.union', nil, fake,
    nil, {'content', 'users'})
end

--[[ Reaching a composed statement the wrong way, in both directions. ]]
do
  local pgmoon = require 'includes.database.driver.pgmoon'
  local fake = {}

  function fake:table(name) return name end

  assert_raises('composed_via_run_is_refused', 'db:composed',
    registry.compile, pgmoon, 'test.union', nil, fake)

  --[[ An empty arm list is refused rather than rendered.

    `SELECT ... FROM () arms` is a syntax error on every backend, and a tag
    attached to no entity type is a branch at the call site rather than a query
    -- the same decision `list()` makes about an empty `IN ()`.
  ]]
  assert_raises('composed_refuses_an_empty_arm_list', 'no arms',
    registry.compile, pgmoon, 'test.union', nil, fake, nil, {})

  assert_raises('arms_passed_to_a_plain_statement_refused', 'composes nothing',
    registry.compile, pgmoon, 'test.delete', {table = 'content'}, fake, nil,
    {'content'})
end

--[[ What `define()` refuses at load, so a broken composition is a load error
  rather than a failure on whichever request first reaches the fallback. ]]
do
  assert_raises('compose_needs_an_arm', 'composition with no arm',
    registry.define, 'test.c1', {sql = '{{arms}}', compose = {}})

  assert_raises('compose_needs_a_separator', 'no separator', registry.define,
    'test.c2', {sql = '{{arms}}', compose = {arm = 'test.arm'}})

  assert_raises('compose_needs_the_arms_macro', 'no {{arms}}', registry.define,
    'test.c3', {sql = 'SELECT 1', compose = {arm = 'test.arm', separator = ','}})

  assert_raises('compose_arm_must_be_defined', 'declare the arm above it',
    registry.define, 'test.c4',
    {sql = '{{arms}}', compose = {arm = 'test.nope', separator = ','}})

  -- The identifiers belong to the arm. Declaring them on the wrapper too would
  -- give two places to look for one guard.
  assert_raises('compose_refuses_its_own_idents', 'they belong', registry.define,
    'test.c5', {
      sql = '{{arms}} WHERE x = {col}',
      compose = {arm = 'test.arm', separator = ','},
      idents = {col = registry.trusted},
      order = {'col'},
    })

  registry.define('test.two_idents', {
    sql = 'SELECT 1 FROM {a} JOIN {b} ON 1 = 1',
    idents = {a = registry.trusted, b = registry.trusted},
    order = {'a', 'b'},
    tables = {'{a}'},
  })

  assert_raises('compose_arm_takes_exactly_one_identifier', 'exactly one',
    registry.define, 'test.c6',
    {sql = '{{arms}}', compose = {arm = 'test.two_idents', separator = ','}})
end

--[[ A literal `%` in an arm survives the join.

  `gsub` reads `%` in a *replacement string* as a capture reference, so joining
  the arms with a string replacement would turn `LIKE '%draft%'` into an error
  or into different SQL. Nothing in the codebase composes a LIKE today, which is
  exactly why this is pinned rather than left to be discovered.
]]
do
  local pgmoon = require 'includes.database.driver.pgmoon'
  local fake = {}

  function fake:table(name) return name end

  registry.define('test.like_arm', {
    sql = "SELECT id FROM {type} WHERE title LIKE '%draft%' AND tag_id = ?",
    idents = {type = registry.trusted},
    order = {'type'},
    tables = {'{type}'},
  })

  registry.define('test.like_union', {
    compose = {arm = 'test.like_arm', separator = ' UNION ALL '},
    sql = '{{arms}}',
  })

  local composed = registry.compile(pgmoon, 'test.like_union', nil, fake, nil,
    {'content', 'page'})

  assert_eq('composed_keeps_a_literal_percent',
    select(2, composed.sql:gsub("LIKE '%%draft%%'", '')), 2)
end

io.write '\n-- a driver that is not reachable --\n'

--[[ `lua-resty-mysql` ships with OpenResty rather than being installed, so
  `module 'resty.mysql' not found` and its page of search paths says the wrong
  thing: the process is not OpenResty, and no rock would fix it. The unit suite
  runs under `lua5.1`, so this is the failure exactly as the command line meets
  it -- which is where a MySQL site actually hits it, since `ophal migrate
  apply` has to run under `resty`.
]]
do
  local mysql = require 'includes.database.driver.resty_mysql'
  local handle, err = mysql.connect({host = '127.0.0.1', database = 'ophal'})

  assert_eq('mysql_without_openresty_refuses', handle, nil)
  assert_truthy('mysql_without_openresty_names_resty',
    tostring(err):match('resty'))
  assert_truthy('mysql_without_openresty_names_the_command',
    tostring(err):match('ophal migrate apply'))
  -- The message it replaced. A search-path dump names the loader rather than
  -- the thing that is wrong.
  assert_eq('mysql_without_openresty_hides_the_search_path',
    tostring(err):match('no file') , nil)
end

io.write(('\n%d passed, %d failed\n'):format(passed, failed))

if failed > 0 then
  os.exit(1)
end
