local version = [[Ophal/0.1-alpha4]]

-- Cache control
if os.getenv [[HTTP_IF_MODIFIED_SINCE]] ~= nil then
  print [[Status: 304 Not Modified
Cache-Control: must-revalidate
]]
  os.exit()
end

print(string.format([[Content-type: text/html; charset=utf-8
X-Powered-By: %s
Expires: Sun, 19 Nov 1978 05:00:00 GMT
Last-Modified: %s
Cache-Control: store, no-cache, must-revalidate, post-check=0, pre-check=0
Keep-Alive: timeout=15, max=90
]], version, os.date([[!%a, %d %b %Y %X GMT]], os.time(os.date([[*t]])) - 15*60)))

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

function bootstrap(main)
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

  main()
end
