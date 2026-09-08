local M = {}

local config = require 'includes.database.config'
local driver_base = require 'includes.database.driver'

local MIGRATION_TABLE = 'ophal_migrations'

local function settings_value(options)
  return options.settings or _G.settings
end

--[[ How a migration reaches the database.

  A migration is DDL that is not known until it runs, so its contract stays a
  function taking SQL -- `ctx.db_query(statement)` -- rather than a statement
  name. What changed under it is where that SQL goes: `db:execute()` on this
  request's connection, which is the layer's own path for ad-hoc text, instead
  of a free function resolving a connection from an ambient identifier.
]]
local function db_query_fn(options)
  if options.db_query then
    return options.db_query
  end

  if type(_G.db_connection) ~= 'function' then
    return nil
  end

  return function(sql, ...)
    return _G.db_connection():execute(sql, ...)
  end
end

local function cache_clear_fn(options)
  return options.cache_clear_all or _G.cache_clear_all
end

--[[ The connection a migration runs against.

  `settings.db.default` has two legal shapes -- the connection table itself, and
  the name of another entry -- and this function read only the second. With a
  settings file written the documented way it indexed the handle table with the
  connection *table* and answered nil, so `ctx.db_handle` was nil for every
  migration. Nothing shipped uses it, which is why it never surfaced.

  `includes/database/config.lua` is the one reading of `settings.db` now, so
  both shapes resolve to an identifier here and neither is special.
]]
local function db_handle(options)
  local settings, resolved, ok

  if options.db_handle ~= nil then
    return options.db_handle
  end

  if type(_G.db_connection) ~= 'function' then
    return nil
  end

  settings = settings_value(options)
  ok, resolved = pcall(config.resolve, settings and settings.db)

  if not ok or resolved == nil or resolved.default == nil then
    return nil
  end

  return _G.db_connection(resolved.default)
end

local function optional_require(module_name)
  local ok, result = pcall(require, module_name)
  if ok then
    return result
  end

  if tostring(result or ''):match("module '" .. module_name:gsub('%.', '%%.') .. "' not found") then
    return nil
  end

  return nil, result
end

--[[ The dialect a migration is written for, from the driver a site configured.

  Migrations branch on `sqlite3` versus `postgresql`, which are dialects -- and
  this used to answer with the *driver* string instead. That worked only while
  the two LuaDBI drivers happened to be named after their dialects: the moment
  a site wrote `driver = 'pgmoon'`, `ophal migrate` answered "unsupported
  migration driver: pgmoon" and no migration could run at all. `lsqlite3` and
  `resty-mysql` would each have hit the same wall.

  Resolving through `includes/database/driver/` is what makes the CLI's driver
  and the worker's driver interchangeable: two drivers over one dialect share
  every migration, which is the same property that lets them share compiled
  statements.
]]
local function dialect_of(driver)
  local module_name = config.driver_module(driver)

  if module_name == nil then
    return nil, ('unsupported migration driver: %s'):format(tostring(driver))
  end

  return driver_base.load(module_name).dialect
end

local function driver_name(options)
  local settings = settings_value(options)
  local db_key, connection

  if type(options.driver) == 'string' and options.driver ~= '' then
    return dialect_of(options.driver:lower())
  end

  if type(settings) ~= 'table' or type(settings.db) ~= 'table' then
    return nil, 'database settings are required for migrations'
  end

  -- `settings.db.default` is the connection table itself in the documented
  -- configuration, and that is the shape `db_connect()` reads. Accepting a
  -- string there too keeps the indirection some settings files use, where
  -- `default` names another key rather than holding the connection.
  db_key = 'default'
  connection = settings.db[db_key]

  if type(connection) == 'string' then
    db_key = connection
    connection = settings.db[db_key]
  end

  if type(connection) ~= 'table' then
    return nil, ('database connection settings missing for key: %s'):format(tostring(db_key))
  end

  if type(connection.driver) ~= 'string' or connection.driver == '' then
    return nil, ('database driver missing for key: %s'):format(tostring(db_key))
  end

  return dialect_of(connection.driver:lower())
end

local function migration_table_sql(driver)
  if driver == 'sqlite3' then
    return [[CREATE TABLE IF NOT EXISTS ophal_migrations(
  id VARCHAR(255) PRIMARY KEY,
  module VARCHAR(255),
  applied_at UNSIGNED BIG INT
)]]
  elseif driver == 'postgresql' then
    return [[CREATE TABLE IF NOT EXISTS ophal_migrations(
  id character varying(255) PRIMARY KEY,
  module character varying(255),
  applied_at bigint
)]]
  end

  return nil, ('unsupported migration driver: %s'):format(tostring(driver))
end

local function run_query(options, query, ...)
  local fn = db_query_fn(options)
  local ok, result

  if type(fn) ~= 'function' then
    return nil, 'db_query() is unavailable'
  end

  ok, result = pcall(fn, query, ...)
  if not ok then
    return nil, result
  end

  return result
end

local function migration_context(options, migration)
  return {
    settings = settings_value(options),
    db_query = db_query_fn(options),
    cache_clear_all = cache_clear_fn(options),
    db_handle = db_handle(options),
    driver = assert(driver_name(options)),
    migration = migration,
    module = migration.module,
    id = migration.id,
  }
end

local function normalize_migration(module_name, migration, index)
  local id

  if type(migration) ~= 'table' then
    return nil, ('%s migration #%d must be a table'):format(module_name, index)
  end

  if type(migration.id) ~= 'string' or migration.id == '' then
    return nil, ('%s migration #%d is missing id'):format(module_name, index)
  end

  if type(migration.up) ~= 'function' then
    return nil, ('%s migration %s is missing up()'):format(module_name, migration.id)
  end

  id = migration.id
  if not id:find(':', 1, true) then
    id = module_name .. ':' .. id
  end

  return {
    id = id,
    module = migration.module or module_name,
    name = migration.name or migration.id,
    up = migration.up,
  }
end

local function append_registry(collected, seen, module_name, registry)
  if registry == nil then
    return true
  end

  if type(registry) ~= 'table' then
    return nil, ('%s migrations must return a list table'):format(module_name)
  end

  for index, migration in ipairs(registry) do
    local normalized, err = normalize_migration(module_name, migration, index)
    if not normalized then
      return nil, err
    end

    if seen[normalized.id] then
      return nil, ('duplicate migration id: %s'):format(normalized.id)
    end

    seen[normalized.id] = true
    collected[#collected + 1] = normalized
  end

  return true
end

local function core_registry(options)
  if options.core_migrations ~= nil then
    return options.core_migrations
  end

  return optional_require('includes.migrations')
end

local function enabled_modules(options)
  if type(options.module_names) == 'table' then
    return options.module_names
  end

  if type(_G.module_list) ~= 'function' then
    local ok, err = pcall(require, 'includes.module')
    if not ok then
      return nil, err
    end
  end

  return module_list()
end

local function module_registry(module_name, options)
  if type(options.load_module_migrations) == 'function' then
    return options.load_module_migrations(module_name)
  end

  if type(options.module_migrations) == 'table' then
    return options.module_migrations[module_name]
  end

  return optional_require('modules.' .. module_name .. '.migrations')
end

local function read_applied_ids(options)
  local rs, err = run_query(options, 'SELECT id FROM ' .. MIGRATION_TABLE .. ' ORDER BY id')
  local applied = {}

  if not rs then
    return nil, err
  end

  for row in rs:rows(true) do
    applied[row.id] = true
  end

  return applied
end

local function record_applied(options, migration)
  return run_query(options,
    'INSERT INTO ' .. MIGRATION_TABLE .. '(id, module, applied_at) VALUES(?, ?, ?)',
    migration.id,
    migration.module,
    os.time()
  )
end

function M.collect(options)
  options = options or {}

  local collected = {}
  local seen = {}
  local core, modules, err

  core, err = core_registry(options)
  if err then
    return nil, err
  end

  local ok, append_err = append_registry(collected, seen, 'core', core)
  if not ok then
    return nil, append_err
  end

  modules, err = enabled_modules(options)
  if err then
    return nil, err
  end

  for _, module_name in ipairs(modules or {}) do
    local registry
    registry, err = module_registry(module_name, options)
    if err then
      return nil, err
    end

    ok, append_err = append_registry(collected, seen, module_name, registry)
    if not ok then
      return nil, append_err
    end
  end

  return collected
end

function M.ensure_store(options)
  options = options or {}

  local driver, err = driver_name(options)
  local sql

  if not driver then
    return nil, err
  end

  sql, err = migration_table_sql(driver)
  if not sql then
    return nil, err
  end

  return run_query(options, sql)
end

function M.status(options)
  options = options or {}

  local migrations, err = M.collect(options)
  local applied_ids, pending, applied_count = nil, nil, 0

  if not migrations then
    return nil, err
  end

  local ensured
  ensured, err = M.ensure_store(options)
  if not ensured then
    return nil, err
  end

  applied_ids, err = read_applied_ids(options)
  if not applied_ids then
    return nil, err
  end

  pending = {}
  for _, migration in ipairs(migrations) do
    if applied_ids[migration.id] then
      applied_count = applied_count + 1
    else
      pending[#pending + 1] = migration
    end
  end

  return {
    total_count = #migrations,
    applied_count = applied_count,
    pending_count = #pending,
    pending = pending,
  }
end

function M.apply(options)
  options = options or {}

  local status, err = M.status(options)
  local applied = {}
  local ok, up_ok, up_err
  local cleared

  if not status then
    return nil, err
  end

  for _, migration in ipairs(status.pending) do
    ok, up_ok, up_err = pcall(migration.up, migration_context(options, migration))
    if not ok then
      return nil, up_ok
    elseif up_ok == false then
      return nil, up_err or ('migration failed: ' .. migration.id)
    elseif up_ok == nil and up_err ~= nil then
      return nil, up_err
    end

    local recorded
    recorded, err = record_applied(options, migration)
    if not recorded then
      return nil, err
    end

    applied[#applied + 1] = migration
  end

  if #applied > 0 and type(cache_clear_fn(options)) == 'function' then
    ok, cleared = pcall(cache_clear_fn(options))
    if not ok then
      return nil, cleared
    end
  end

  return {
    applied = applied,
    applied_count = #applied,
    total_count = status.total_count,
    pending_count = 0,
  }
end

return M
