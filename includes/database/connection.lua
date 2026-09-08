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

local setmetatable, select, type, ipairs = setmetatable, select, type, ipairs

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

--[[ Reached whenever `_handle` is nil, which is both interesting cases.

  A connection that has never been used is nil because connecting is lazy; a
  released one is nil because releasing clears it. So the hot path is a single
  nil test that covers connecting on first use *and* refusing a connection that
  has outlived its request, and neither costs anything when the handle is there.
]]
local function handle_of(self)
  local s = own(self)
  local handle = s.handle
  local err

  if handle ~= nil then
    return handle
  end

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

local function compiled_for(self, name)
  local s = own(self)
  local compiled = s.compiled[name]

  if compiled == nil then
    compiled = registry.compile(s.driver, name, nil, self)
    s.compiled[name] = compiled
  end

  return compiled
end

local function run_compiled(self, compiled, ...)
  local handle = handle_of(self)
  local s = state[self]
  local res, err

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

  return db_result.wrap(s.driver.rows(res))
end

--[[ Run a declared statement.

  The whole cost above the driver call is one hash lookup for the compiled
  statement and one increment for accounting. No SQL is built, and varargs pass
  straight through to a binding driver without a table being allocated for them.
]]
function Connection:run(name, ...)
  return run_compiled(self, compiled_for(self, name), ...)
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

  order = decl.order or fail('%s declares no identifier order', name)
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
    state[stmt] = {
      connection = self,
      compiled = registry.compile(s.driver, name, values, self),
    }

    node.statement = stmt
  end

  return stmt
end

function Statement:run(...)
  local s = own(self)

  return run_compiled(s.connection, s.compiled, ...)
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
function Connection:field(table_name, field_name)
  local cache = own(self).schema
  local columns = cache[table_name]

  if columns == nil then
    local rs = self:run('core.table_schema', table_name)

    columns = {}

    for row in rs:rows(true) do
      columns[row.field_name] = row.field_name
    end

    cache[table_name] = columns
  end

  return columns[field_name]
end

function Connection:schema_cache_clear()
  own(self).schema = {}
end

function Connection:last_insert_id(table_name, field_name)
  local decl = registry.declaration('core.last_insert_id')
  local row

  if decl.idents then
    row = self:with('core.last_insert_id', table_name, field_name):run():fetch()
  else
    row = self:run('core.last_insert_id'):fetch()
  end

  return row and row[1]
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
  return handle_of(self)
end

--[[ Ad-hoc SQL, for migrations, the installer and the CLI.

  A declared statement is the request path's contract; this is for text that is
  not known until it runs. Attribution falls back to the tokenizer, which is
  what that parser is for.
]]
function Connection:execute(sql, ...)
  local compiled = registry.compile_text(own(self).driver, sql)

  return run_compiled(self, compiled, ...)
end

--[[ Give the connection up.

  Pooled on success, closed on failure, and closed if a statement ever errored
  on it -- a handle whose last statement failed may hold a live transaction or
  unread protocol traffic. `_handle` is cleared either way, so any later use
  takes the slow path in `handle_of()` and raises rather than reaching a socket
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
    schema = {},
  }

  return conn
end

M.Connection = Connection

return M
