-- Jailed environment functions and modules
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
  table = table,
  require = require,
  unpack = unpack,
  pairs = pairs,
  ipairs = ipairs,
  rawset = rawset,
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
  main = main,
}
local env = env

-- Load settings
settings = {modules = {}}
require [[settings]]
env.settings = settings

-- The actual module
local write, setfenv = io.write, setfenv
module [[ophal]]

function bootstrap()
  -- Jail
  setfenv(0, env) -- global environment
  setfenv(1, env) -- bootstrap environment
  setfenv(main, env) -- script environment
  env._G = env
  env.env = env

  -- output functions
  function env.print(s)
    write(tostring(s))
  end

  function env.echo(...)
    for _, v in pairs({...}) do
      write(tostring(v))
    end
  end

  -- Parse query string
  do
    function split(s, sep)
      sep = lpeg.P(sep)
      local elem = lpeg.C((1 - sep)^0)
      local p = lpeg.Ct(elem * (sep * elem)^0)
      return lpeg.match(p, s)
    end
    local list = split(os.getenv [[QUERY_STRING]] or [[]], [[&]])
    local parsed = {}
    if list then
      local tmp
      require [[socket/url]]
      for _, v in pairs(list) do
        if #v > 0 then
          tmp = split(v, [[=]])
          parsed[tmp[1]] = socket.url.unescape(tmp[2] or [[]])
        end
      end
    end
    env._GET = parsed
  end

  -- load core
  require [[includes.common]]
  require [[includes.theme]]

  -- load modules
  for k, v in pairs(settings.modules) do
    if v then
      require([[modules.]] .. k .. [[.init]])
    end
  end
end
