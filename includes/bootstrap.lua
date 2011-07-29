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
  seawolf = {
    filesystem = require [[seawolf.filesystem]],
    text = require [[seawolf.text]],
  },
  _SERVER = os.getenv,
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
local setfenv = setfenv
module [[ophal]]

function bootstrap()
  -- Jail
  setfenv(0, env) -- global environment
  setfenv(1, env) -- bootstrap environment
  setfenv(main, env) -- script environment
  env._G = env
  env.env = env

  -- init cgi
  require [[includes.cgi]]

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
