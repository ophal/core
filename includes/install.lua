local db_config = require 'includes.database.config'

local M = {}

local HTACCESS_CONTENT = [[SetHandler Ophal_Security_Do_Not_Remove
Options None
Options +FollowSymLinks

]]

local DEPENDENCIES = {
  {machine_name = 'lfs', name = 'LuaFilesystem', required = true},
  {machine_name = 'uuid', name = 'luuid', required = true},
  -- The database bindings are per backend, so none of them is unconditionally
  -- required: a PostgreSQL site needs pgmoon and no SQLite binding, and a MySQL
  -- site needs neither because `lua-resty-mysql` ships with OpenResty.
  {machine_name = 'lsqlite3', name = 'lsqlite3 (SQLite)', required = false},
  {machine_name = 'pgmoon', name = 'pgmoon (PostgreSQL)', required = false},
  {machine_name = 'lpeg', name = 'LPEG', required = true},
  {machine_name = 'dkjson', name = "David Kolf's JSON", required = true},
  {machine_name = 'seawolf.variable', name = 'Seawolf: variable', required = true},
  {machine_name = 'seawolf.fs', name = 'Seawolf: filesystem', required = true},
  {machine_name = 'seawolf.text', name = 'Seawolf: text', required = true},
  {machine_name = 'seawolf.behaviour', name = 'Seawolf: behaviour', required = true},
  {machine_name = 'seawolf.contrib', name = 'Seawolf: contrib', required = true},
}

local DEFAULT_MODULES = {
  lorem_ipsum = true,
  content = false,
  comment = false,
  user = false,
  tag = false,
  menu = false,
  file = false,
  test = false,
}

local function copy_table(values)
  local copied = {}

  for key, value in pairs(values or {}) do
    copied[key] = value
  end

  return copied
end

local function join_path(root, child)
  if root == nil or root == '' or root == '.' then
    return child
  end

  if child:sub(1, 1) == '/' then
    return child
  end

  if root:sub(-1) == '/' then
    return root .. child
  end

  return root .. '/' .. child
end

local function default_settings_table()
  return {
    version = {
      core = true,
      number = true,
      revision = true,
    },
    slash = string.sub(package.config, 1, 1),
    modules = {},
    debugapi = true,
  }
end

local function file_exists(path, options)
  if type(options.file_exists) == 'function' then
    return options.file_exists(path)
  end

  local fh = io.open(path, 'r')
  if fh then
    fh:close()
    return true
  end

  return false
end

local function ensure_dir_exists(path, options)
  if type(options.ensure_dir_exists) == 'function' then
    return options.ensure_dir_exists(path)
  end

  local lfs = options.lfs or require 'lfs'
  local current = ''

  if path:sub(1, 1) == '/' then
    current = '/'
  end

  for part in path:gmatch('[^/]+') do
    if current == '' or current == '/' then
      current = current .. part
    else
      current = current .. '/' .. part
    end
    lfs.mkdir(current)
  end

  return true
end

local function write_file(path, content, options)
  if type(options.write_file) == 'function' then
    return options.write_file(path, content)
  end

  local fh = assert(io.open(path, 'w'))
  fh:write(content)
  fh:close()
  return true
end

local function load_vault(path, options)
  if type(options.load_vault_file) == 'function' then
    return options.load_vault_file(path)
  end

  local chunk, err = loadfile(path)
  if not chunk then
    return nil, err
  end

  local ok, value = pcall(chunk)
  if not ok then
    return nil, value
  end

  if type(value) ~= 'table' then
    return nil, ('%s must return a table'):format(path)
  end

  return value
end

local function load_settings(path, vault, options)
  if type(options.load_settings_file) == 'function' then
    return options.load_settings_file(path, vault)
  end

  local chunk, err = loadfile(path)
  local settings
  local ok, builder

  if not chunk then
    return nil, err
  end

  ok, builder = pcall(chunk)
  if not ok then
    return nil, builder
  end

  if type(builder) ~= 'function' then
    return nil, ('%s must return a function'):format(path)
  end

  settings = default_settings_table()
  builder(settings, vault)
  return settings
end

--[[ The installer's driver names are the query layer's.

  `includes/database/config.lua` decides whether a name resolves to a binding,
  so asking it is what stops this file from keeping a second list that drifts
  from that one. It had already drifted: this function used to be
  `if sqlite then SQLite3 else PostgreSQL`, so every name it did not recognize
  became PostgreSQL. MySQL was a supported backend for a whole stage before the
  installer learned the word -- `ophal install init --db-driver mysql` wrote a
  PostgreSQL vault and `install check` reported a MySQL site as PostgreSQL,
  both silently rather than refusing.

  An absent driver is still PostgreSQL, because that is the documented default
  for an install that names none. An unrecognized one is an error now.
]]
local DRIVER_NAMES = {
  lsqlite3 = 'SQLite3',
  pgmoon = 'PostgreSQL',
  resty_mysql = 'MySQL',
}

local function normalize_driver_name(driver)
  if driver == nil or driver == '' then
    return 'PostgreSQL'
  end

  return DRIVER_NAMES[db_config.driver_module(tostring(driver)) or '']
end

local function known_driver_names()
  local names = {}

  for _, name in pairs(DRIVER_NAMES) do
    names[#names + 1] = name
  end

  table.sort(names)

  return table.concat(names, ', ')
end

-- The answer `includes/database/config.lua` gives a settings file that still
-- names a LuaDBI binding, given here at the point the name is typed rather
-- than at the first query of a site that has already been installed.
local function unknown_driver_error(driver)
  local replacement = db_config.retired_driver(tostring(driver))

  if replacement ~= nil then
    return ('database driver %q is gone; Ophal spells that backend %q now')
      :format(tostring(driver), replacement)
  end

  return ('unknown database driver %q (known: %s)')
    :format(tostring(driver), known_driver_names())
end

local function driver_defaults(driver, config)
  local name = normalize_driver_name(driver)

  if name == nil then
    return nil, unknown_driver_error(driver)
  end

  -- SQLite is a file and has no credentials. The two server backends differ
  -- only in the port they default to.
  if name == 'SQLite3' then
    return {
      driver = 'SQLite3',
      database = config.db_database or 'ophal.sqlite3',
    }
  end

  return {
    driver = name,
    database = config.db_database or 'ophal',
    username = config.db_username or 'ophal',
    password = config.db_password or 'ophal',
    host = config.db_host or 'localhost',
    port = config.db_port or (name == 'MySQL' and '3306' or '5432'),
  }
end

local function runtime_warning_for_driver(driver)
  local name = normalize_driver_name(driver)

  if name == 'SQLite3' then
    return 'SQLite3 is supported for development, CLI, tests, and low-scale compatibility. PostgreSQL is the required production backend for the performance architecture.'
  end

  --[[ What is left of MySQL's difference, said where somebody choosing MySQL
    will read it.

    It used to lead with the interpreter: `lua-resty-mysql` is cosockets down to
    the socket and has no blocking mode, so the command line could not run under
    the `lua5.1` the `ophal` script named. That stopped being a MySQL problem on
    2026-09-10, when Ophal became LuaJIT-only and the `ophal` script started
    naming `resty` for every backend. The data difference is real and remains.
  ]]
  if name == 'MySQL' then
    return 'MySQL is supported. Note that lua-resty-mysql leaves a BIGINT column as a string, so compare one with tonumber: arithmetic coerces and comparison does not.'
  end
end

--[[ The site hash, from the CSPRNG.

  This used to try three shapes of uuid binding and, failing all of them, fall
  back to

      math.randomseed(os.time())
      return ('install-%d-%06d'):format(os.time(), math.random(0, 999999))

  which puts its own seed in the string it returns: given the value, the six
  digits are recomputable, so its entropy is zero rather than small. Nothing
  reads `site.hash` today, which is why it never mattered -- and is exactly why
  it would have mattered later, the first time something signed with it.

  `includes/random.lua` reads a CSPRNG or raises, so there is no longer a weak
  path to fall into. Failing the install is the correct outcome: a site whose
  secret is guessable should not be created.
]]
local function generate_site_hash(options)
  if type(options.generate_site_hash) == 'function' then
    return tostring(options.generate_site_hash())
  end

  return require('includes.random').hex(32)
end

local function build_config(options)
  local modules = copy_table(DEFAULT_MODULES)
  local enabled = options.modules_enabled or {}
  local disabled = options.modules_disabled or {}
  local db, db_err

  for _, name in ipairs(enabled) do
    modules[name] = true
  end

  for _, name in ipairs(disabled) do
    modules[name] = false
  end

  db, db_err = driver_defaults(options.db_driver, options)

  if not db then
    return nil, db_err
  end

  return {
    site_name = options.site_name or 'Ophal',
    files_path = options.files_path or 'files',
    site_hash = options.site_hash or generate_site_hash(options),
    frontpage = options.frontpage or 'lorem_ipsum',
    theme_name = options.theme_name or 'basic',
    modules = modules,
    db = db,
  }
end

local function sorted_keys(tbl)
  local keys = {}

  for key in pairs(tbl or {}) do
    keys[#keys + 1] = key
  end

  table.sort(keys)
  return keys
end

-- `init()` builds the config once and hands the same table to both renderers,
-- so building it here is the standalone case -- and the one that can fail,
-- because that is where the driver name is read.
local function config_for(options)
  options = options or {}

  if options.config then
    return options.config
  end

  return build_config(options)
end

function M.render_settings(options)
  local config, config_err = config_for(options)
  local lines

  if not config then
    return nil, config_err
  end

  lines = {
    'return function(settings, vault)',
    "  settings.language = 'en'",
    "  settings.language_dir = 'ltr'",
    '  settings.site = {',
    ("    frontpage = %q,"):format(config.frontpage),
    ("    name = %q,"):format(config.site_name),
    '    hash = vault.site.hash,',
    "    logo_title = 'The Ophal Project',",
    "    logo_path = 'images/ophalproject.png',",
    ("    files_path = %q,"):format(config.files_path),
    '  }',
    '  settings.debugapi = true',
    '  settings.maintenance_mode = false',
    '  settings.output_buffering = false',
    '  settings.sessionapi = {',
    '    enabled = true,',
    '    ttl = 86400,',
    '    lock_ttl = 120,',
    '  }',
    '  settings.formapi = false',
    "  settings.date_format = '!%Y-%m-%d %H:%M UTC'",
    '  settings.route_aliases_storage = false',
    '  settings.route_aliases_prepend_language = false',
    '  settings.route_redirects_storage = false',
    '  settings.route_redirects_prepend_language = false',
    '  settings.modules = {',
  }

  for _, name in ipairs(sorted_keys(config.modules)) do
    lines[#lines + 1] = ("    [%q] = %s,"):format(name, tostring(config.modules[name]))
  end

  lines[#lines + 1] = '  }'
  lines[#lines + 1] = '  settings.db = vault.db'
  lines[#lines + 1] = '  settings.theme = {'
  lines[#lines + 1] = ("    name = %q,"):format(config.theme_name)
  lines[#lines + 1] = '  }'
  lines[#lines + 1] = 'end'
  lines[#lines + 1] = ''

  return table.concat(lines, '\n')
end

function M.render_vault(options)
  local config, config_err = config_for(options)
  local db, lines

  if not config then
    return nil, config_err
  end

  db = config.db
  lines = {
    'local m = {',
    '  site = {',
    ("    hash = %q,"):format(config.site_hash),
    '  },',
    '  db = {',
    '    default = {',
    ("      driver = %q,"):format(db.driver),
    ("      database = %q,"):format(db.database),
  }

  -- Written for whatever backend carries credentials rather than for one
  -- named backend: SQLite has a file and nothing else, and MySQL needs exactly
  -- what PostgreSQL needs.
  if db.username ~= nil then
    lines[#lines + 1] = ("      username = %q,"):format(db.username)
    lines[#lines + 1] = ("      password = %q,"):format(db.password)
    lines[#lines + 1] = ("      host = %q,"):format(db.host)
    lines[#lines + 1] = ("      port = %q,"):format(db.port)
  end

  lines[#lines + 1] = '    },'
  lines[#lines + 1] = '  },'
  lines[#lines + 1] = '}'
  lines[#lines + 1] = ''
  lines[#lines + 1] = 'return m'
  lines[#lines + 1] = ''

  return table.concat(lines, '\n')
end

function M.check(options)
  options = options or {}

  local require_module = options.require_module or require
  local root_dir = options.output_dir or '.'
  local settings_path = join_path(root_dir, 'settings.lua')
  local vault_path = join_path(root_dir, 'vault.lua')
  local results = {
    dependencies = {},
    settings_path = settings_path,
    vault_path = vault_path,
    root_dir = root_dir,
    ok = true,
  }
  local lfs = options.lfs
  local settings_exists, vault_exists, vault, settings, err, files_path, files_dir

  for _, dependency in ipairs(DEPENDENCIES) do
    local ok, value = pcall(require_module, dependency.machine_name)
    results.dependencies[#results.dependencies + 1] = {
      machine_name = dependency.machine_name,
      name = dependency.name,
      required = dependency.required,
      found = ok,
      error = ok and nil or value,
    }
    if dependency.required and not ok then
      results.ok = false
    end
  end

  settings_exists = file_exists(settings_path, options)
  vault_exists = file_exists(vault_path, options)
  results.settings_exists = settings_exists
  results.vault_exists = vault_exists

  if settings_exists and vault_exists then
    vault, err = load_vault(vault_path, options)
    if not vault then
      results.ok = false
      results.settings_error = err
      return results
    end

    settings, err = load_settings(settings_path, vault, options)
    if not settings then
      results.ok = false
      results.settings_error = err
      return results
    end

    local declared_driver = (((vault or {}).db or {}).default or {}).driver
      or (((settings or {}).db or {}).default or {}).driver

    results.database_driver = normalize_driver_name(declared_driver)
    results.runtime_warning = runtime_warning_for_driver(declared_driver)

    -- A name no binding answers to is reported here rather than left to fail
    -- at the site's first query. `check` exists to be run before that query.
    if results.database_driver == nil then
      results.ok = false
      results.database_error = unknown_driver_error(declared_driver)
    end

    files_path = settings.site and settings.site.files_path
    results.files_path = files_path
    if not files_path then
      results.ok = false
      results.files_error = 'settings.site.files_path is not set'
      return results
    end

    if files_path:sub(1, 1) == '/' then
      files_dir = files_path
    else
      files_dir = join_path(root_dir, files_path)
    end

    results.files_dir = files_dir

    if not lfs then
      local ok_lfs, loaded = pcall(require, 'lfs')
      if ok_lfs then
        lfs = loaded
      end
    end

    if lfs then
      local mode = lfs.attributes(files_dir, 'mode')
      if mode == 'file' then
        results.ok = false
        results.files_error = ("created file directory '%s' is a file, not a directory"):format(files_dir)
      elseif mode ~= 'directory' then
        results.ok = false
        results.files_error = ("file directory not found: %s"):format(files_dir)
      elseif not lfs.attributes(files_dir, 'permissions'):match('w') then
        results.ok = false
        results.files_error = ("file directory is not writable: %s"):format(files_dir)
      else
        results.files_writable = true
      end
    end
  end

  return results
end

function M.init(options)
  options = options or {}

  local root_dir = options.output_dir or '.'
  local settings_path = join_path(root_dir, 'settings.lua')
  local vault_path = join_path(root_dir, 'vault.lua')
  local config, config_err = build_config(options)
  local files_dir, htaccess_path

  if not config then
    return nil, config_err
  end

  files_dir = config.files_path:sub(1, 1) == '/' and config.files_path or join_path(root_dir, config.files_path)
  htaccess_path = join_path(files_dir, '.htaccess')

  if not options.force then
    if file_exists(settings_path, options) then
      return nil, ('settings file already exists: %s'):format(settings_path)
    end
    if file_exists(vault_path, options) then
      return nil, ('vault file already exists: %s'):format(vault_path)
    end
  end

  ensure_dir_exists(root_dir, options)
  ensure_dir_exists(files_dir, options)

  write_file(settings_path, M.render_settings({config = config}), options)
  write_file(vault_path, M.render_vault({config = config}), options)
  write_file(htaccess_path, HTACCESS_CONTENT, options)

  return {
    settings_path = settings_path,
    vault_path = vault_path,
    files_dir = files_dir,
    htaccess_path = htaccess_path,
    config = config,
  }
end

return M
