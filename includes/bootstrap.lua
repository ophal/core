local version = {
  core = 'Ophal',
  number = '0.2',
  -- revision = 'dev',
  homepage = 'ophal.org',
}

-- Jailed environment functions and modules
env = {
  io = io,
  os = os,
  tonumber = tonumber,
  type = type,
  module = module,
  pcall = pcall,
  nopcall = function(f, ...) return true, f(...) end,
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
  rawget = rawget,
  error = error,
  debug = debug,
  package = package,
  string = string,
  math = math,
  next = next,
  tostring = tostring,
  setmetatable = setmetatable,
  getmetatable = getmetatable,
  select = select,
  _SERVER = os.getenv,
  _SESSION = nil,
  _VERSION = _VERSION,
  lfs = nil,
  lpeg = nil,
  uuid = nil,
  socket = nil,
  theme = {},
  mobile = {},
  base = {
    system_root = '',
    route = '/',
    url = '',
    path = '',
  },
  output_buffer = {},
  ophal = {
    version = nil,
    modules = {},
    routes = {},
    aliases = {},
    redirects = {},
    blocks = {},
    regions = {},
    title = '',
    header_title = '',
    cookies = {},
    header = nil,
    session = nil,
  },
}

-- Build settings
settings = (function()
  local settings = {
    version = {
      core = true,
      number = true,
      revision = true,
    },
    slash = string.sub(package.config,1,1),
    modules = {},
    debugapi = true,
  }

  -- Load settings.lua and vault.lua
  local _, vault = pcall(require, 'vault')
  local _, settings_builder = pcall(require, 'settings')
  if type(settings_builder) == 'function' then
    settings_builder(settings, vault)
  end

  return settings
end)()

env.settings = settings

-- Build version
if settings.version.core then
  if settings.version.number then
    if settings.version.revision then
      env.ophal.version = ('%s %s-%s (%s)'):format(version.core, version.number, version.revision, version.homepage)
    else
      env.ophal.version = ('%s %s (%s)'):format(version.core, version.number, version.homepage)
    end
  else
    env.ophal.version = ('%s (%s)'):format(version.core, version.homepage)
  end
end

-- Detect nginx
if ngx then
  env.ngx = ngx
  env.pcall = env.nopcall
  for k, v in pairs(getfenv(0, ngx)) do
    env[k] = v
  end
end

-- The actual module
local setfenv, type, env = setfenv, type, env
module 'ophal'

function bootstrap(phase, main)
  if type(main) ~= 'function' then main = function() end end

  local status, err, exit_bootstrap

  -- Jail
  setfenv(0, env) -- global environment
  setfenv(1, env) -- bootstrap environment
  setfenv(main, env) -- script environment
  env._G = env
  env.env = env

  local phases = {
    -- 1. Lua and Seawolf libraries
    function ()
      env.lfs = require 'lfs'
      env.lpeg = require 'lpeg'
      env.uuid = require 'uuid'

      env.socket = require 'socket'
      env.socket.url = require 'socket.url'

      env.seawolf = require 'seawolf'.__build('variable', 'fs', 'text', 'behaviour', 'contrib')
    end,

    -- 2. Debug API
    function ()
      if settings.debugapi then
        require 'includes.debug'
      end
    end,

    -- 3. Load native server API
    function ()
      if ngx then
        require 'includes.server.nginx'
      else
        require 'includes.server.cgi'
      end
    end,

    -- 4. Mobile API,
    function ()
      if settings.mobile then
        require 'includes.mobile'
      end
    end,

    -- 5. Load Ophal server API
    function ()
      require 'includes.server.init'
    end,

    -- 6. Check installer
    function ()
      if (_SERVER 'SCRIPT_NAME' or '/index.cgi') == base.route .. 'index.cgi' and not seawolf.fs.is_file 'settings.lua' then
        require 'includes.common'
        redirect(('%s%sinstall.cgi'):format(base.system_root, base.route))
        return -1
      end
    end,

    -- 7. Session API,
    function ()
      local empty = seawolf.variable.empty
      if not empty(settings.sessionapi) then
        require 'includes.session'
        session_start()
      end
    end,

    -- 8. Route API,
    function ()
      require 'includes.route'
      build_base()
    end,

    -- 9. Core API,
    function ()
      require 'includes.common'
      require 'includes.locale'
      require 'includes.module'
      require 'includes.theme'
      require 'includes.pager'
      if settings.formapi then
        require 'includes.form'
      end
    end,

    -- 10. Modules,
    function ()
      module_load_all()
    end,

    -- 11. Boot,
    function ()
      module_invoke_all 'boot'
    end,

    -- 12. Database API,
    function ()
      if settings.db ~= nil then
        require 'includes.database.init'
        if settings.db.default ~= nil then
          db_connect()
          if settings.route_aliases_storage then
            route_aliases_load()
          end
          if settings.route_redirects_storage then
            route_redirects_load()
          end
        end
      end
    end,

    -- 13. Init,
    function ()
      route_redirect()
      module_invoke_all 'init'
    end,

    -- 14. Full,
    function ()
      -- call hook route to load handlers
      -- TODO: implement route cache
      ophal.routes = route_build_routes()

      theme_blocks_load()
      theme_regions_load()

      -- process current route
      init_route()
    end,
  }

  -- Loop over phase
  for p = 1, (phase or #phases) do
    status, err = pcall(phases[p])
    if not status then
      io.write(([[

bootstrap[%s]: %s]]):format(p, err or ''))
      exit_bootstrap = true
      break
    elseif err == -1 then
      exit_bootstrap = true
      break
    end
  end

  -- execute script
  if not exit_bootstrap then
    status, err = pcall(main)
    if not status then
      io.write([[

bootstrap[main]: ]] .. (err or ''))
    end
  end

  -- The end
  exit_ophal()
end
