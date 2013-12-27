local version = ('Ophal/0.1-alpha10 (%s)'):format(_VERSION)

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
  lfs = nil,
  lpeg = nil,
  uuid = nil,
  socket = nil,
  theme = {},
  mobile = {},
  base_root = '',
  base_path = '/',
  language = 'en',
  base_url = '',
  output_buffer = {},
  ophal = {
    version = version,
    modules = {},
    paths = {},
    aliases = {},
    title = '',
    header_title = '',
    cookies = {},
    header = nil,
    session = nil,
  },
}

-- Load settings
settings = {modules = {}}
pcall(require, 'settings')
env.settings = settings
if settings.language then
  env.language = settings.language
end

-- Detect nginx
if ngx then
  env.ngx = ngx
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

      require 'seawolf.variable'
      require 'seawolf.fs'
      require 'seawolf.text'
      require 'seawolf.behaviour'
      require 'seawolf.contrib'
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
      if (_SERVER 'SCRIPT_NAME' or '/index.cgi') == base_path .. 'index.cgi' and not seawolf.fs.is_file 'settings.lua' then
        redirect(('%s%sinstall.cgi'):format(base_root, base_path))
        return -1
      end
    end,

    -- 7. Session API,
    function ()
      if settings.sessionapi then
        require 'includes.session'
        session_start()
      end
    end,

    -- 8. Path API,
    function ()
      require 'includes.path'
    end,

    -- 9. Core API,
    function ()
      require 'includes.common'
      require 'includes.module'
      require 'includes.theme'
      require 'includes.pager'
      if settings.formapi then
        require 'includes.form'
        require 'includes.file'
      end
    end,

    -- 10. Modules,
    function ()
      local status, err

      for k, v in pairs(settings.modules) do
        if v then
          status, err = pcall(require, 'modules.' .. k .. '.init')
          if not status then
            print('bootstrap: ' .. err)
          end
        end
      end
    end,

    -- 11. Boot,
    function ()
      module_invoke_all 'boot'
    end,

    -- 12. Menu API,
    function ()
      require 'includes.menu'
    end,

    -- 13. Database API,
    function ()
      if settings.db ~= nil then
        require 'includes.database'
        if settings.db.default ~= nil then
          db_connect()
        end
      end
    end,

    -- 14. Init,
    function ()
      module_invoke_all 'init'
    end,

    -- 15. Full,
    function ()
      -- call hook menu to load path handlers
      -- TODO: implement path cache
      ophal.paths = module_invoke_all 'menu'

      -- process current path
      init_path()
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
