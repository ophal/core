local version = [[Ophal/0.1-alpha5]]

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
  _SERVER = os.getenv,
  lfs = require [[lfs]],
  lpeg = require [[lpeg]],
  theme = {},
  ophal = {version = version},
}

-- Load settings
settings = {modules = {}}
require [[settings]]
env.settings = settings

-- The actual module
local setfenv, type, env = setfenv, type, env
module [[ophal]]

function bootstrap(main)
  if type(main) ~= [[function]] then main = function() end end

  -- Jail
  setfenv(0, env) -- global environment
  setfenv(1, env) -- bootstrap environment
  setfenv(main, env) -- script environment
  env._G = env
  env.env = env

  -- CGI init
  require [[includes.cgi]]

  -- load Seawolf
  require [[seawolf.variable]]
  require [[seawolf.fs]]
  require [[seawolf.text]]
  
  -- Create base URL
  base_root = (_SERVER [[HTTPS]] ~= nil and _SERVER [[HTTPS]] == [[on]]) and [[https]] or [[http]]
  base_root = base_root .. '://' .. (_SERVER [[HTTP_HOST]] or [[]])
  base_url = base_root

  local dir = seawolf.text.trim(seawolf.fs.dirname(_SERVER [[SCRIPT_NAME]] or [[]]), [[\,/]])
  if dir ~= [[]] then
    base_path = [[/]] .. dir
    base_url = base_url .. base_path
    base_path = base_path .. [[/]]
  else
    base_path = [[/]]
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

  main()
end
