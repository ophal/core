function bootstrap()

  local write = io.write

  -- Allowed functions and Lua modules
  env = {
    io = io,
    os = os,
    tonumber = tonumber,
    type = type,
    module = module,
    pcall = pcall,
    loadstring = loadstring,
    setfenv = setfenv,
    getfenv = getfenv,
    assert = assert,
    print = function (s) write(tostring(s)); end,
    echo = function (...) for _, v in pairs({...}) do write(tostring(v)); end end,
    table = table,
    require = require,
    unpack = unpack,
    pairs = pairs,
    error = error,
    debug = debug,
    package = package,
    string = string,
    next = next,
    tostring = tostring,
    setmetatable = setmetatable,
    getmetatable = getmetatable,
    lfs = require [[lfs]],
    lpeg = require [[lpeg]],
    theme = {},
    settings = {},
    main = main,
  }
  env._G = env
  env.env = env

  setfenv(main, env) -- script environment
  setfenv(0, env) -- global environment
  setfenv(1, env) -- bootstrap environment

  require [[settings]]
  require [[includes.common]]
  require [[includes.theme]]

  -- load modules
  for k, v in pairs(settings.modules) do
    if v then
      require([[modules.]] .. k)
    end
  end

  -- run script
  main()
end
