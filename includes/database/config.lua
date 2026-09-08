--[[ One reading of `settings.db`.

  `settings.db` is a map of identifier to connection table, and it has had two
  incompatible readings. `db_connect()` reads `settings.db['default']`, so
  `default` *is* the connection -- the documented shape, what
  `examples/vault.lua` shows and what `includes/install.lua` generates.
  `includes/migrate.lua`'s `db_handle()` reads `settings.db.default` as a *key*,
  so it wants a string naming another entry; `driver_name()` beside it was
  taught both shapes and `db_handle()` was not, which is why `ctx.db_handle` is
  nil for every migration run from a settings file written the documented way.

  Both shapes are legal and both are read here, once, so nothing downstream has
  to choose. Everything else -- the router, migrations, the installer, the CLI
  -- asks this module.
]]

local M = {}

--[[ Driver name to the module under `includes/database/driver/`.

  `sqlite3` means lsqlite3. It meant LuaDBI until 2026-09-08, and the swap is
  deliberate rather than gradual: LuaDBI reads integer columns with 32-bit
  precision, which nothing above the binding can repair, so a timestamp breaks
  in January 2038 and a file over 2 GB reads wrong today. Ophal is experimental
  and a swap is allowed to break an upgrade -- but it has to break it legibly,
  which is what `driver/lsqlite3.lua` does when the binding is absent.

  The names are what a settings file writes, and they are stable across
  runtimes: `sqlite3` is lsqlite3 under both OpenResty and the `lua5.1` CLI, and
  `pgmoon` picks its socket type from whichever it is running under. That is why
  `driver` and `dialect` are separate keys.
]]
local DRIVERS = {
  sqlite3 = 'lsqlite3',
  lsqlite3 = 'lsqlite3',
  postgresql = 'luadbi_postgresql',
  mysql = 'luadbi_mysql',
  pgmoon = 'pgmoon',
  ['resty-mysql'] = 'resty_mysql',
}

--[[ Names that used to work, and what to do instead.

  Answered apart from an unknown driver, because "no such driver" is a typo and
  this is an upgrade. A site that spelled the LuaDBI SQLite binding explicitly
  gets told what replaced it and why, rather than being told its spelling is
  wrong.
]]
local RETIRED = {
  ['luadbi-sqlite3'] = 'sqlite3',
  luadbi_sqlite3 = 'sqlite3',
}

local DEFAULT_KEY = 'default'

local resolved

local function fail(message, ...)
  error(('database config: ' .. message):format(...), 0)
end

-- An identifier reaches log lines, cache keys and the CLI, so it is held to
-- the shape of a Lua name rather than accepted as any table key.
local function valid_identifier(name)
  return type(name) == 'string' and name:match('^[%a_][%w_]*$') ~= nil
end

function M.driver_module(driver)
  if type(driver) ~= 'string' or driver == '' then
    return nil
  end

  return DRIVERS[driver:lower()]
end

function M.retired_driver(driver)
  if type(driver) ~= 'string' then
    return nil
  end

  return RETIRED[driver:lower()]
end

function M.drivers()
  local names = {}

  for name in pairs(DRIVERS) do
    names[#names + 1] = name
  end

  table.sort(names)

  return names
end

local function build_connection(name, config)
  local module_name = M.driver_module(config.driver)
  local copy = {}

  if type(config.driver) ~= 'string' or config.driver == '' then
    fail('connection %q has no driver', name)
  end

  -- Checked here rather than at the first query, so a typo fails at boot
  -- instead of on whichever path happens to reach the database first.
  if module_name == nil then
    local replacement = M.retired_driver(config.driver)

    if replacement ~= nil then
      fail('connection %q names %q, which Ophal no longer has. SQLite is\n'
        .. 'lsqlite3 now, because LuaDBI reads integer columns with 32-bit\n'
        .. "precision. Write driver = '%s' and install the binding:\n"
        .. '  luarocks install lsqlite3complete\n'
        .. 'More: https://github.com/ophal/core',
        name, config.driver, replacement)
    end

    fail('connection %q names unknown driver %q (known: %s)',
      name, config.driver, table.concat(M.drivers(), ', '))
  end

  for key, value in pairs(config) do
    copy[key] = value
  end

  -- Stamped so a connection failure can say which connection failed.
  -- `db_connect()` logs the database, the driver and the host, and never the
  -- identifier, which is the one thing that names it in settings.
  copy.name = name
  copy.driver_module = module_name

  return copy
end

--[[ Resolve `settings.db` into connections and the default's identifier.

  Returns `{connections = {[name] = config}, default = name}`, or nil plus a
  message. Called once per worker: settings do not change at runtime.
]]
function M.resolve(db_settings)
  local connections, default = {}, nil
  local aliased

  if type(db_settings) ~= 'table' then
    fail('settings.db must be a table')
  end

  aliased = db_settings[DEFAULT_KEY]

  for name, config in pairs(db_settings) do
    if type(config) == 'table' then
      if not valid_identifier(name) then
        fail('connection name %q is not an identifier', tostring(name))
      end

      connections[name] = build_connection(name, config)
    end
  end

  if type(aliased) == 'string' then
    -- One hop, never a chain: a string pointing at a string is a configuration
    -- error rather than a link to follow. Chains invite cycles and buy nothing.
    if connections[aliased] == nil then
      fail('default names %q, which is not a connection', aliased)
    end

    default = aliased
  elseif type(aliased) == 'table' then
    default = DEFAULT_KEY
  elseif aliased ~= nil then
    fail('default must be a connection table or the name of one, got %s',
      type(aliased))
  end

  return {connections = connections, default = default}
end

local function current()
  if resolved == nil then
    resolved = M.resolve(((_G.settings or {}).db) or {})
  end

  return resolved
end

--[[ The configuration for one identifier, or the default's when none is given.

  An unknown identifier raises. It does not fall back to the default: silently
  answering `db_connection('legacy')` with the site's own database is how an
  integration writes into the wrong place.
]]
function M.get(name)
  local state = current()

  if name == nil then
    if state.default == nil then
      fail('no default connection is configured; set settings.db.default')
    end

    return state.connections[state.default]
  end

  if state.connections[name] == nil then
    fail('no connection named %q is configured', tostring(name))
  end

  return state.connections[name]
end

function M.default_name()
  return current().default
end

function M.names()
  local state, names = current(), {}

  for name in pairs(state.connections) do
    names[#names + 1] = name
  end

  table.sort(names)

  return names
end

-- Settings do not change at runtime, so this exists for the unit suite and for
-- the CLI, which builds a settings table after this module may have loaded.
function M.reset()
  resolved = nil
end

return M
