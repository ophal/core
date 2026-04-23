local M = {}

local EXIT_OK = 0
local EXIT_ERROR = 1
local EXIT_UNIMPLEMENTED = 2

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
    '  migrate                  Reserved for migration automation',
    '  module enable NAME       Reserved for module enable automation',
    '  module disable NAME      Reserved for module disable automation',
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
    return unimplemented('migrate', stderr)
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

    return unimplemented(('module %s %s'):format(args[2], args[3]), stderr)
  end

  output(stderr, ('Unknown command: %s\n\n%s'):format(command, usage()))
  return EXIT_ERROR
end

function M.main(argv)
  return M.run(argv or arg or {})
end

return M
