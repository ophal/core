local M = {}

local MIGRATION_TABLE = 'ophal_migrations'

local function settings_value(options)
  return options.settings or _G.settings
end

local function db_query_fn(options)
  return options.db_query or _G.db_query
end

local function cache_clear_fn(options)
  return options.cache_clear_all or _G.cache_clear_all
end

local function db_handle(options)
  if options.db_handle ~= nil then
    return options.db_handle
  end

  local settings = settings_value(options)
  local db_key = settings and settings.db and (settings.db.default or 'default')

  if _G.dbh and db_key then
    return _G.dbh[db_key]
  end
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

local function driver_name(options)
  local settings = settings_value(options)
  local db_key, connection

  if type(options.driver) == 'string' and options.driver ~= '' then
    return options.driver:lower()
  end

  if type(settings) ~= 'table' or type(settings.db) ~= 'table' then
    return nil, 'database settings are required for migrations'
  end

  db_key = settings.db.default or 'default'
  connection = settings.db[db_key]
  if type(connection) ~= 'table' then
    return nil, ('database connection settings missing for key: %s'):format(db_key)
  end

  if type(connection.driver) ~= 'string' or connection.driver == '' then
    return nil, ('database driver missing for key: %s'):format(db_key)
  end

  return connection.driver:lower()
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
