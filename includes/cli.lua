local M = {}

local EXIT_OK = 0
local EXIT_ERROR = 1
local EXIT_UNIMPLEMENTED = 2
local MODULE_OVERRIDE_FILE = 'settings/modules.lua'

local function output(writer, text)
  writer(text)
end

local function default_stdout(text)
  io.write(text)
end

local function default_stderr(text)
  io.stderr:write(text)
end

local function normalize_args(argv)
  local args = {}

  for i = 1, #(argv or {}) do
    args[#args + 1] = argv[i]
  end

  return args
end

local function usage()
  return table.concat({
    'Usage: ophal COMMAND [ARGS]',
    '',
    'Commands:',
    '  cache clear              Clear framework caches in the current runtime',
    '  sha256 PASSWORD          Generate a legacy SHA-256 password hash',
    '  install                  Reserved for installer automation',
    '  migrate [status|apply]   Apply or inspect registered database migrations',
    '  module enable NAME       Enable a module via settings/modules.lua',
    '  module disable NAME      Disable a module via settings/modules.lua',
    '  help                     Show this help',
    '',
  }, '\n')
end

local function ensure_cache_runtime()
  _G.settings = _G.settings or {modules = {}}
  _G.ophal = _G.ophal or {modules = {}}

  if type(_G.cache_clear_all) ~= 'function' then
    local ok, err = pcall(require, 'includes.cache')
    if not ok then
      return nil, err
    end
  end

  return _G.cache_clear_all
end

local function cache_clear(options)
  local clear = options.cache_clear_all or _G.cache_clear_all
  local ok, err

  if type(clear) ~= 'function' then
    clear, err = ensure_cache_runtime()
    if type(clear) ~= 'function' then
      return nil, err or 'cache_clear_all() is unavailable'
    end
  end

  ok, err = pcall(clear)
  if not ok then
    return nil, err
  end

  return true
end

local function legacy_sha256(password)
  local ok, sha256 = pcall(require, 'includes.sha256')

  if not ok then
    return nil, sha256
  end

  return sha256.hash256(password or '')
end

local function copy_table(values)
  local copied = {}

  for key, value in pairs(values or {}) do
    copied[key] = value
  end

  return copied
end

local function module_override_path(options)
  return options.modules_file or MODULE_OVERRIDE_FILE
end

local function write_module_override_table(path, overrides)
  local lfs = require 'lfs'
  local dir = path:match('^(.*)/[^/]+$')
  local handle

  local function ensure_dir_exists(dir_path)
    local current = ''

    if dir_path:sub(1, 1) == '/' then
      current = '/'
    end

    for part in dir_path:gmatch('[^/]+') do
      if current == '' or current == '/' then
        current = current .. part
      else
        current = current .. '/' .. part
      end
      lfs.mkdir(current)
    end
  end

  if dir and dir ~= '' then
    ensure_dir_exists(dir)
  end

  handle = assert(io.open(path, 'w'))
  handle:write('return {\n')

  local keys = {}
  for key in pairs(overrides) do
    keys[#keys + 1] = key
  end
  table.sort(keys)

  for _, key in ipairs(keys) do
    handle:write(('  [%q] = %s,\n'):format(key, tostring(overrides[key])))
  end

  handle:write('}\n')
  handle:close()
end

local function read_module_overrides(options)
  local path = module_override_path(options)

  if type(options.read_module_overrides) == 'function' then
    return options.read_module_overrides(path)
  end

  local chunk, err = loadfile(path)
  if not chunk then
    if tostring(err or ''):match('No such file') then
      return {}
    end
    return nil, err
  end

  local ok, result = pcall(chunk)
  if not ok then
    return nil, result
  end

  if result == nil then
    return {}
  elseif type(result) ~= 'table' then
    return nil, ('%s must return a table for CLI management'):format(path)
  end

  return copy_table(result)
end

local function write_module_overrides(overrides, options)
  local path = module_override_path(options)

  if type(options.write_module_overrides) == 'function' then
    return options.write_module_overrides(path, overrides)
  end

  return write_module_override_table(path, overrides)
end

local function load_settings(options, include_module_overrides)
  if type(options.load_settings) == 'function' then
    return options.load_settings(include_module_overrides)
  end

  package.loaded['settings'] = nil
  package.loaded['settings.modules'] = nil

  local ok, loader = pcall(require, 'includes.settings_loader')
  if not ok then
    return nil, loader
  end

  return loader.build({
    include_module_overrides = include_module_overrides,
  })
end

local function prepare_migrate_runtime(options)
  local settings, ok, err, seawolf_builder

  if type(options.prepare_migrate_runtime) == 'function' then
    return options.prepare_migrate_runtime()
  end

  settings = load_settings(options, true)
  if type(settings) ~= 'table' then
    return nil, settings or 'unable to load settings'
  end

  _G.settings = settings
  _G.ophal = {modules = {}}

  ok, seawolf_builder = pcall(require, 'seawolf')
  if not ok then
    return nil, seawolf_builder
  end
  _G.seawolf = seawolf_builder.__build('contrib')

  package.loaded['includes.module'] = nil
  package.loaded['includes.migrate'] = nil

  ok, err = pcall(require, 'includes.log')
  if not ok then
    return nil, err
  end

  ok, err = pcall(require, 'includes.module')
  if not ok then
    return nil, err
  end

  ok, err = pcall(require, 'includes.cache')
  if not ok then
    return nil, err
  end

  if type(settings.db) ~= 'table' then
    return nil, 'database settings are required for migrations'
  end

  ok, err = pcall(require, 'includes.database.init')
  if not ok then
    return nil, err
  end

  ok, err = pcall(db_connect)
  if not ok then
    return nil, err
  end

  return {
    settings = settings,
  }
end

local function run_migrate_status(options)
  local migrate

  if type(options.migrate_status) == 'function' then
    return options.migrate_status()
  end

  local runtime, err = prepare_migrate_runtime(options)
  if not runtime then
    return nil, err
  end

  local ok, result = pcall(require, 'includes.migrate')
  if not ok then
    return nil, result
  end
  migrate = result

  return migrate.status({
    settings = runtime.settings,
  })
end

local function run_migrate_apply(options)
  local migrate

  if type(options.migrate_apply) == 'function' then
    return options.migrate_apply()
  end

  local runtime, err = prepare_migrate_runtime(options)
  if not runtime then
    return nil, err
  end

  local ok, result = pcall(require, 'includes.migrate')
  if not ok then
    return nil, result
  end
  migrate = result

  return migrate.apply({
    settings = runtime.settings,
  })
end

local function module_exists(name, options)
  if type(options.module_exists) == 'function' then
    return options.module_exists(name)
  end

  local handle = io.open(('modules/%s/init.lua'):format(name), 'r')
  if handle then
    handle:close()
    return true
  end

  return false
end

local function is_enabled(value)
  return value ~= nil and value ~= false
end

local function module_set_enabled(name, desired, options)
  local base_settings, overrides, base_modules, base_enabled, effective_enabled
  local updated, path

  if name == 'system' and not desired then
    return nil, 'system module cannot be disabled'
  end

  if not module_exists(name, options) then
    return nil, ('unknown module: %s'):format(name)
  end

  base_settings = load_settings(options, false)
  if type(base_settings) ~= 'table' then
    return nil, base_settings or 'unable to load base settings'
  end

  overrides = read_module_overrides(options)
  if type(overrides) ~= 'table' then
    return nil, overrides or 'unable to load module overrides'
  end

  base_modules = base_settings.modules or {}
  base_enabled = is_enabled(base_modules[name])
  if overrides[name] ~= nil then
    effective_enabled = is_enabled(overrides[name])
  else
    effective_enabled = base_enabled
  end

  if effective_enabled == desired then
    return {
      changed = false,
      enabled = effective_enabled,
      path = module_override_path(options),
    }
  end

  updated = copy_table(overrides)
  if desired == base_enabled then
    updated[name] = nil
  else
    updated[name] = desired
  end

  path = module_override_path(options)
  local ok, err = pcall(write_module_overrides, updated, options)
  if not ok then
    return nil, err
  elseif err ~= nil then
    return nil, err
  end

  return {
    changed = true,
    enabled = desired,
    path = path,
  }
end

local function unimplemented(command, stderr)
  output(stderr, ('Command not implemented yet: %s\n'):format(command))
  return EXIT_UNIMPLEMENTED
end

function M.usage()
  return usage()
end

function M.run(argv, options)
  local args = normalize_args(argv)
  options = options or {}

  local stdout = options.stdout or default_stdout
  local stderr = options.stderr or default_stderr
  local command = args[1]

  if command == nil or command == '' or command == 'help' or command == '--help' or command == '-h' then
    output(stdout, usage())
    return EXIT_OK
  end

  if command == 'cache' then
    if args[2] ~= 'clear' then
      output(stderr, 'Usage: ophal cache clear\n')
      return EXIT_ERROR
    end

    local ok, err = cache_clear(options)
    if not ok then
      output(stderr, ('cache clear failed: %s\n'):format(tostring(err)))
      return EXIT_ERROR
    end

    output(stdout, 'Caches cleared.\n')
    return EXIT_OK
  end

  if command == 'sha256' then
    if args[2] == nil then
      output(stderr, 'Usage: ophal sha256 PASSWORD\n')
      return EXIT_ERROR
    end

    local digest, err = legacy_sha256(args[2])
    if digest == nil then
      output(stderr, ('sha256 failed: %s\n'):format(tostring(err)))
      return EXIT_ERROR
    end

    output(stdout, digest .. '\n')
    return EXIT_OK
  end

  if command == 'install' then
    return unimplemented('install', stderr)
  end

  if command == 'migrate' then
    local action = args[2] or 'apply'
    local result, err

    if action == 'status' then
      result, err = run_migrate_status(options)
      if not result then
        output(stderr, ('migrate status failed: %s\n'):format(tostring(err)))
        return EXIT_ERROR
      end

      output(stdout, ('Migration status: %d applied, %d pending.\n'):format(
        result.applied_count or 0,
        result.pending_count or 0
      ))
      for _, migration in ipairs(result.pending or {}) do
        output(stdout, ('- %s\n'):format(migration.id))
      end
      return EXIT_OK
    elseif action == 'apply' then
      result, err = run_migrate_apply(options)
      if not result then
        output(stderr, ('migrate apply failed: %s\n'):format(tostring(err)))
        return EXIT_ERROR
      end

      if (result.applied_count or 0) == 0 then
        output(stdout, 'No pending migrations.\n')
      else
        output(stdout, ('Applied %d migration(s).\n'):format(result.applied_count))
        for _, migration in ipairs(result.applied or {}) do
          output(stdout, ('- %s\n'):format(migration.id))
        end
      end

      return EXIT_OK
    end

    output(stderr, 'Usage: ophal migrate [status|apply]\n')
    return EXIT_ERROR
  end

  if command == 'module' then
    if args[2] ~= 'enable' and args[2] ~= 'disable' then
      output(stderr, 'Usage: ophal module enable NAME\n       ophal module disable NAME\n')
      return EXIT_ERROR
    end

    if args[3] == nil or args[3] == '' then
      output(stderr, ('Usage: ophal module %s NAME\n'):format(args[2]))
      return EXIT_ERROR
    end

    local desired = args[2] == 'enable'
    local result, err = module_set_enabled(args[3], desired, options)

    if not result then
      output(stderr, ('module %s failed: %s\n'):format(args[2], tostring(err)))
      return EXIT_ERROR
    end

    if result.changed then
      output(stdout, ("Module '%s' %s via %s.\n"):format(
        args[3],
        desired and 'enabled' or 'disabled',
        result.path
      ))
    else
      output(stdout, ("Module '%s' already %s.\n"):format(
        args[3],
        desired and 'enabled' or 'disabled'
      ))
    end

    return EXIT_OK
  end

  output(stderr, ('Unknown command: %s\n\n%s'):format(command, usage()))
  return EXIT_ERROR
end

function M.main(argv)
  return M.run(argv or arg or {})
end

return M
