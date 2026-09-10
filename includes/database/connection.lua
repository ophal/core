--[[ A connection object bound to one identifier, which cannot be repointed.

  The dangerous thing in the old shape was never the accessor -- it was that
  every operation resolved a connection implicitly. `db_query()`, `db_field()`,
  `db_limit()`, `db_last_insert_id()`, `db_table_schema_sql()` and
  `db_claim_jobs_sql()` all read an ambient `db_id` that `db_set_db_id()` could
  change, so any of them could change meaning between two adjacent lines where
  neither line mentions a database.

  Here the identifier is fixed when the object is made and every operation is a
  method on an object the caller is already holding, so a mid-operation switch
  is not expressible. Another database means another object:

    local db     = db_connection()
    local legacy = db_connection('legacy')

  Writing any field raises, so `db.name = 'legacy'` is an error rather than a
  silent repointing. `rawset` would still get through -- nothing in Lua stops
  it -- but that is deliberate subversion, not the accident being designed out.
]]

local M = {}

local config = require 'includes.database.config'
local driver_base = require 'includes.database.driver'
local registry = require 'includes.database.registry'
local request_state = require 'includes.request_state'
local stats = require 'includes.database.stats'
local db_result = require 'includes.database.result'
local http_cache = require 'includes.http_cache'

local setmetatable, select, type, ipairs = setmetatable, select, type, ipairs
local unpack = unpack or table.unpack

local Connection = {}
local Statement = {}

local function fail(message, ...)
  error(('database: ' .. message):format(...), 0)
end

--[[ Where a connection's state lives: beside the object, never on it.

  `__newindex` fires only for keys a table does not already hold, so state kept
  as fields on the object would be writable in spite of the metamethod --
  `conn._name = 'legacy'` would repoint it silently, which is precisely the
  hazard this object exists to remove. That was not a hypothesis: the first
  version of this file stored the fields directly and
  `connection_field_write_refused` caught it.

  So the object itself is empty. Every key misses, `__index` finds a method or
  nothing, and every assignment reaches `__newindex` and raises. It is the same
  rule `includes/request_state.lua` documents for its routed names, in the other
  direction.

  Weak keys, so a connection is collectable once nothing holds it.
]]
local state = setmetatable({}, {__mode = 'k'})

local function own(self)
  local s = state[self]

  if s == nil then
    fail('not a connection')
  end

  return s
end

--[[ Reached whenever the handle is nil, which is both interesting cases.

  A connection that has never been used has none because connecting is lazy; a
  released one has none because releasing clears it. So the hot path is a single
  nil test on a field the caller already holds -- `s.handle or connect(s)` --
  that covers connecting on first use *and* refusing a connection which has
  outlived its request, and costs nothing when the handle is there.
]]
local function connect(s)
  local handle, err

  if s.released then
    fail('connection %q was released at the end of its request; ask for a new one',
      s.name)
  end

  -- A connection object stashed in a module upvalue and reused next request
  -- would otherwise reach a socket that request does not own. This is the
  -- database-level form of the load-time capture class closed in stage 8.2.
  if s.request ~= request_state.current() then
    fail('connection %q belongs to another request', s.name)
  end

  handle, err = s.driver.connect(s.config)

  if handle == nil then
    if type(log_error) == 'function' then
      log_error('database connection failed', {
        event = 'database_connection_failed',
        connection = s.name,
        driver = s.config.driver,
        database = s.config.database,
        host = s.config.host,
      })
    end

    fail('connection %q failed: %s', s.name, tostring(err))
  end

  s.handle = handle

  return handle
end

--[[ Run a compiled statement against a connection's state.

  The state rather than the object, and that is not only to save a second weak
  lookup on the hot path. A `Statement` from `with()` has to remember what to
  run against, and remembering the *object* defeats the weak key that lets a
  connection be collected: Lua 5.1 marks the values of a weak-keyed table
  strongly and has no ephemerons, so an entry whose value can reach its own key
  is never removed. A statement holding its connection therefore pinned that
  connection, its compiled table, its identifier tree and its schema cache for
  the life of the worker -- one per request, on every request that deleted an
  entity or loaded a row by field. Holding the state instead breaks the cycle,
  because nothing in the state names the object.

  `connection_is_collectable_after_with` is the assertion, and it was red before
  this.
]]
local function run_compiled(s, compiled, ...)
  local handle = s.handle or connect(s)
  local res, err

  --[[ A response built from a normalized table cannot carry a projection
    validator, so reading one takes this request out of the cacheable set.

    Phase 9's rule is "cacheable if the request observed at least one projection
    version", and routing observes one on **every** request -- so that guard was
    always satisfied and nothing checked the response's *content* was described
    by the versions in the validator. `comment/fetch` is the case that showed
    it: it reads the normalized `comment` table, which has no projection and
    therefore no version, and it was served `public` with an ETag that never
    moved. Change the comment, ask again with `If-None-Match`, get **304**, and
    a shared cache holds the old list until some unrelated projection version
    happens to change.

    This is the same argument stage 8.6b made about identifiers: refusing the
    *class* here is what stops the next module that reads a normalized table
    reintroducing it. A `http_cache.disable()` at each service is the
    patch-by-patch shape and would be forgotten once.

    It sits beside `record_bucket` rather than inside it because that function
    returns early when `settings.performance.query_stats` is off, which is the
    default -- `stats_enabled()` gates the *counting*, not the classification.
    A declared statement carries `bucket` from compile time, so this costs a
    string comparison.

    The cost is real and bounded: a response served from a projection's
    normalized fallback loses caching for the length of a deferred window.
    `db_frontpage_stale` is that scenario and its budget already says two
    normalized reads.
  ]]
  if compiled.bucket == 'normalized' then
    http_cache.disable()
  end

  stats.record_bucket(compiled.bucket, compiled.tables)

  res, err = s.driver.execute(handle, compiled, ...)

  if res == nil then
    -- A handle whose statement errored may hold a live transaction or unread
    -- protocol traffic, so it must never go back to the pool. Marking it here
    -- is what makes that decision at release time.
    s.failed = true

    if type(log_error) == 'function' then
      log_error('database query failed', {
        event = 'database_query_failed',
        connection = s.name,
        statement = compiled.name,
        error = err,
      })
    end

    fail('%s failed on %q: %s', compiled.name, s.name, tostring(err))
  end

  -- Named, on every backend: two of the three drivers return rows as hashes and
  -- cannot answer positionally at all, so the layer promises only what all of
  -- them can keep. `includes/database/result.lua` says what that costs.
  return db_result.named(s.driver.rows(res))
end

--[[ Run a declared statement.

  The whole cost above the driver call is one hash lookup for the compiled
  statement and one increment for accounting. No SQL is built, and varargs pass
  straight through to a binding driver without a table being allocated for them.
]]
function Connection:run(name, ...)
  local s = own(self)
  local compiled = s.compiled[name]

  if compiled == nil then
    compiled = registry.compile(s.driver, name, nil, self)
    s.compiled[name] = compiled
  end

  return run_compiled(s, compiled, ...)
end

--[[ Run a declared statement whose width is decided by the caller.

  For a `?*` slot: an IN list as wide as an account has roles, which was the
  last value interpolation in the codebase and was injectable --
  `tests/bench/injection_probe.lua` shows one hostile id returning a row from a
  WHERE clause written to match nothing, on all three backends.

    db:list('user.role_permissions', role_ids)

  The values arrive as a table rather than as varargs, because the caller has
  one already and the arity has to be read before anything is compiled. That is
  one table per call, against none for `run()`, and it is the right trade for a
  statement whose width varies: the compiled form is still cached per width per
  worker, so nothing is built here beyond the first call at each size.

  `#values` is the arity, so a list with a nil in the middle is a shorter list.
  That is Lua's own rule for `#` and there is nothing useful this could do
  instead -- a caller with optional values wants a different statement, not a
  hole in this one.
]]
function Connection:list(name, values)
  local s = own(self)
  local arity, compiled, per_name

  if type(values) ~= 'table' then
    fail('%s takes a list of values, got %s', tostring(name), type(values))
  end

  arity = #values
  per_name = s.lists[name]

  if per_name == nil then
    per_name = {}
    s.lists[name] = per_name
  end

  compiled = per_name[arity]

  if compiled == nil then
    compiled = registry.compile(s.driver, name, nil, self, arity)
    per_name[arity] = compiled
  end

  return run_compiled(s, compiled, unpack(values, 1, arity))
end

--[[ The same, returning `nil, err` instead of raising.

  `includes/projection.lua` wraps `db_query` in a `pcall` to get this shape.
  That is a database concern living in the projection layer, so it moves here.
]]
function Connection:try(name, ...)
  local ok, result = pcall(self.run, self, name, ...)

  if not ok then
    return nil, result
  end

  return result
end

--[[ A statement whose identifiers are fixed, memoized.

  Identifier values are part of the compile key rather than runtime parameters,
  so they are validated and quoted once per distinct value per worker instead of
  being concatenated into SQL on every call -- which is what
  `'DELETE FROM ' .. entity.type` does today.

    db:with('entity.delete', entity.type):run(entity.id)

  Values are positional, in the declaration's `order`, so the call site
  allocates nothing. After the first use per value the whole thing is a walk of
  one table per identifier.
]]
function Connection:with(name, ...)
  local s = own(self)
  local decl = registry.declaration(name)
  local node = s.with
  local order, count, values, stmt

  if decl == nil then
    fail('%s is not defined', tostring(name))
  end

  -- A statement with identifiers always has an order; `registry.define()`
  -- refuses one without. So no order means no identifiers, and this is a
  -- statement to run directly.
  order = decl.order
    or fail('%s declares no identifiers; run it with :run()', name)
  count = select('#', ...)

  if count ~= #order then
    fail('%s takes %d identifiers, got %d', name, #order, count)
  end

  node = node[name]

  if node == nil then
    node = {}
    s.with[name] = node
  end

  for i = 1, count do
    local value = (select(i, ...))
    local child = node[value]

    if child == nil then
      child = {}
      node[value] = child
    end

    node = child
  end

  stmt = node.statement

  if stmt == nil then
    values = {}

    for i, key in ipairs(order) do
      values[key] = (select(i, ...))
    end

    stmt = setmetatable({}, Statement)
    -- The connection's state, never the connection: see `run_compiled()`.
    state[stmt] = {
      owner = s,
      compiled = registry.compile(s.driver, name, values, self),
    }

    node.statement = stmt
  end

  return stmt
end

--[[ A statement built from one arm per value, joined by its declaration.

  The tag listing's normalized fallback:

    db:composed('tag.legacy_rows', {'content', 'page'})
      :run(tag_id, tag_id, offset, count)

  It is the third and last shape whose SQL is not fully known at load. `run()`
  covers a fixed statement, `list()` a fixed statement of varying width, and
  this one a statement of varying *structure* -- a UNION with one arm per entity
  type a tag is attached to. Between them there is nothing left that needs
  `execute()`, which is the point of the exercise rather than a side effect: the
  ability to pass SQL text from application code is what the injection surface
  was made of.

  Parameters stay positional and stay in reading order -- one per arm, in arm
  order, then the wrapper's own. That falls out of composing the body before
  placeholders are split rather than being arranged for.

  Memoized per value tuple per connection, the way `with()` memoizes per
  identifier, so a listing over the same two types compiles once per worker.
]]
function Connection:composed(name, values)
  local s = own(self)
  local decl = registry.declaration(name)
  local node, stmt

  if decl == nil then
    fail('%s is not defined', tostring(name))
  end

  if type(values) ~= 'table' then
    fail('%s takes a list of arm values, got %s', name, type(values))
  end

  node = s.composed[name]

  if node == nil then
    node = {}
    s.composed[name] = node
  end

  for i = 1, #values do
    local child = node[values[i]]

    if child == nil then
      child = {}
      node[values[i]] = child
    end

    node = child
  end

  stmt = node.statement

  if stmt == nil then
    stmt = setmetatable({}, Statement)
    -- The connection's state, never the connection: see `run_compiled()`.
    state[stmt] = {
      owner = s,
      compiled = registry.compile(s.driver, name, nil, self, nil, values),
    }

    node.statement = stmt
  end

  return stmt
end

function Statement:run(...)
  local s = own(self)

  return run_compiled(s.owner, s.compiled, ...)
end

function Statement:sql()
  local compiled = own(self).compiled

  return compiled.sql or table.concat(compiled.chunks, '?')
end

Statement.__index = Statement

function Statement.__newindex()
  fail('a statement is immutable')
end

--[[ The only way to open a transaction.

  "Never return a pooled connection that is inside a transaction" is an
  invariant rather than a comment because there is no other way to start one:
  the block either commits or rolls back before this returns, so the connection
  is in a known state by the time release sees it. Nothing in the codebase opens
  an explicit transaction today, which is what makes pooling safe to adopt --
  and why this exists before the first caller needs it.
]]
function Connection:transaction(fn)
  local s = own(self)
  local ok, result

  if s.in_transaction then
    fail('connection %q is already in a transaction', s.name)
  end

  self:run 'core.begin'
  s.in_transaction = true

  ok, result = pcall(fn, self)

  if ok then
    local committed, err = pcall(self.run, self, 'core.commit')

    s.in_transaction = false

    if not committed then
      error(err, 0)
    end

    return result
  end

  pcall(self.run, self, 'core.rollback')
  s.in_transaction = false

  error(result, 0)
end

--[[ Whether a table has a column, cached per connection.

  Per connection, not per table name. The old cache
  (`includes/database/init.lua`) was keyed by table name alone with no
  connection in the key, which is correct only while exactly one connection
  exists -- the moment a second is configured, which is the whole point of this
  work, the second is answered with the first's columns.

  It doubles as the identifier whitelist: `load_by_field` in `modules/user`,
  `modules/file` and `modules/comment` interpolates a column name into SQL and
  uses this to decide whether it may. A name the real schema does not have
  returns nil, so a whitelist cannot drift from the database.
]]
local function schema_of(self, table_name)
  local cache = own(self).schema
  local columns = cache[table_name]

  if columns == nil then
    local rs = self:run('core.table_schema', table_name)

    columns = {}

    for row in rs:rows(true) do
      columns[row.field_name] = row.field_name
    end

    -- A table that does not exist caches as an empty set rather than as a
    -- miss, so a name that is not there is read once per worker instead of on
    -- every call. That matters here more than for a real table: the names that
    -- do not exist are the hostile ones.
    cache[table_name] = columns
  end

  return columns
end

function Connection:field(table_name, field_name)
  return schema_of(self, table_name)[field_name]
end

--[[ Whether this connection's database has a table by this name.

  The table counterpart of `field()` above, and the resolver a declaration
  reaches for when a `{table}` identifier's value comes from data rather than
  from the framework's own source. `modules/entity` is that case: an entity type
  arrives in the URL, `entity/delete/<type>/<id>`, and becomes the table a
  DELETE names.

  It rests on the same argument `field()` does, which is why it is here rather
  than being a list somewhere: the answer comes from `core.table_schema`,
  scoped to this connection's own schema, so the whitelist is the database and
  cannot drift from it. A list of allowed tables would be a second copy of the
  schema, maintained by hand, and wrong the first time a table was added.

  It costs no query `field()` would not: the schema read is per table and
  cached, so a `{table}` and a `{field}` on the same table share one. A table
  with no columns is one that does not exist -- `information_schema` has nothing
  to say about a table that was never created.

  It answers the name rather than true so that it can be used as a resolver
  directly, which return nil for "no" the way every other resolver does.
]]
function Connection:table(table_name)
  return next(schema_of(self, table_name)) ~= nil and table_name or nil
end

function Connection:schema_cache_clear()
  own(self).schema = {}
end

--[[ The id the last INSERT on this connection produced.

  The table and the column are identifiers rather than parameters because
  PostgreSQL needs them to build a sequence name, and passing them the same way
  on every dialect is what keeps the call one shape -- the SQLite and MySQL
  bodies simply have no slot to put them in.

  Every dialect aliases the value as `id`, so the row is read by name like every
  other row the layer returns.
]]
function Connection:last_insert_id(table_name, field_name)
  local row = self:with('core.last_insert_id', table_name, field_name)
    :run()
    :fetch(true)

  return row and row.id
end

function Connection:name()
  return own(self).name
end

function Connection:driver()
  return own(self).driver.name
end

function Connection:dialect()
  return own(self).driver.dialect
end

-- The raw driver handle, for the migration and installer paths that still
-- speak SQL directly. Deliberately awkward to reach: nothing on a request path
-- should want it.
function Connection:handle()
  local s = own(self)

  return s.handle or connect(s)
end

--[[ Ad-hoc SQL, for migrations, the installer and the CLI.

  A declared statement is the request path's contract; this is for text that is
  not known until it runs. Attribution falls back to the tokenizer, which is
  what that parser is for.
]]
function Connection:execute(sql, ...)
  local s = own(self)

  return run_compiled(s, registry.compile_text(s.driver, sql), ...)
end

--[[ Give the connection up.

  Pooled on success, closed on failure, and closed if a statement ever errored
  on it -- a handle whose last statement failed may hold a live transaction or
  unread protocol traffic. The handle is cleared either way, so any later use
  falls into `connect()` and raises rather than reaching a socket
  the pool has given to somebody else.
]]
function Connection:release(ok)
  local s = own(self)
  local handle = s.handle

  if handle ~= nil and s.in_transaction then
    -- Rolled back before the handle is given up, so what the pool receives is
    -- never inside a transaction. `transaction()` normally leaves nothing to do
    -- here; this is the path where a caller's error escaped it.
    pcall(self.run, self, 'core.rollback')
    s.in_transaction = false
    ok = false
  end

  s.released = true
  s.handle = nil

  if handle == nil then
    return false
  end

  return s.driver.release(handle, ok ~= false and not s.failed)
end

Connection.__index = Connection

function Connection.__newindex(self, key)
  fail('a connection is bound to %q at construction; ask for another object rather than repointing this one (tried to set %q)',
    own(self).name, tostring(key))
end

function Connection.__tostring(self)
  local s = own(self)

  return ('<ophal connection %s via %s>'):format(s.name, s.driver.name)
end

--[[ Build a connection object. Not exported to the application.

  `db_connection()` in `includes/database/init.lua` is the accessor, and it
  memoizes per identifier per request, so two calls with one name give one
  object. This never connects: connecting happens on first use.
]]
function M.open(name)
  local settings_for = config.get(name)
  local conn = setmetatable({}, Connection)

  state[conn] = {
    name = settings_for.name,
    config = settings_for,
    driver = driver_base.load(settings_for.driver_module),
    request = request_state.current(),
    compiled = {},
    with = {},
    -- Compiled forms keyed by name and then by width, for `list()`.
    lists = {},
    composed = {},
    schema = {},
  }

  return conn
end

M.Connection = Connection

return M
