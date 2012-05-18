local version = [[Ophal/0.1-alpha7]]

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
  select = select,
  _SERVER = os.getenv,
  lfs = require [[lfs]],
  lpeg = require [[lpeg]],
  theme = {},
  base_root = [[]],
  base_path = [[/]],
  base_url = [[]],
  output_buffer = {},
  ophal = {
    version = version,
    modules = {},
    paths = {},
    aliases = {},
    title = [[]],
    header_title = [[]],
  },
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

  -- load Seawolf
  require [[seawolf.variable]]
  require [[seawolf.fs]]
  require [[seawolf.text]]

  -- Load debug API
  if settings.debugapi then
    require [[includes.debug]]
  end

  -- CGI init
  require [[includes.cgi]]

  -- Prepare path
  if _GET.q == nil then
    _GET.q = settings.site.frontpage
  end
  require [[includes.path]]

  -- Create base URL
  base_root = (_SERVER [[HTTPS]] ~= nil and _SERVER [[HTTPS]] == [[on]]) and [[https]] or [[http]]
  base_root = base_root .. '://' .. (_SERVER [[HTTP_HOST]] or [[]])
  base_url = base_root

  local dir = seawolf.text.trim(seawolf.fs.dirname(_SERVER [[SCRIPT_NAME]] or [[]]), [[\,/]])
  if dir ~= [[]] then
    base_path = [[/]] .. dir
    base_url = base_url .. base_path
    base_path = base_path .. [[/]]
  end

  -- load core (phase 1)
  require [[includes.common]]
  require [[includes.module]]
  require [[includes.theme]]

  local status, err

  -- load modules
  for k, v in pairs(settings.modules) do
    if v then
      status, err = pcall(require, [[modules.]] .. k .. [[.init]])
      if not status then
        io.write(([[bootstrap: %s]]):format(err))
      end
    end
  end

  -- call hook boot
  module_invoke_all [[boot]]

  -- load core (phase 2)
  require [[includes.menu]]

  -- database connection (phase 3)
  if settings.db ~= nil then
    require [[includes.database]]
    db_connect()
  end

  -- call hook init
  module_invoke_all [[init]]

  -- call hook menu to load path handlers
  -- TODO: implement path cache
  ophal.paths = module_invoke_all [[menu]]

  -- process current path
  init_path()

  -- execute script
  status, err = pcall(main)
  if not status then
    io.write(([[bootstrap: %s]]):format(err))
  end

  -- call hook exit
  module_invoke_all [[exit]]

  -- flush output buffer
  if settings.output_buffering then
    output_flush()
  end
end

