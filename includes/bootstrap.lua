local version = [[Ophal/0.1-alpha9 (]] .. _VERSION .. [[)]]

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
  next = next,
  tostring = tostring,
  setmetatable = setmetatable,
  getmetatable = getmetatable,
  select = select,
  _SERVER = os.getenv,
  _SESSION = nil,
  lfs = require [[lfs]],
  lpeg = require [[lpeg]],
  cgic = require [[cgic]],
  uuid = require [[uuid]],
  theme = {},
  mobile = {},
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
    cookies = {},
    header = nil,
    session = nil,
  },
}

-- Load settings
settings = {modules = {}}
pcall(require, [[settings]])
env.settings = settings

-- The actual module
local setfenv, type, env = setfenv, type, env
module [[ophal]]

function bootstrap(phase, main)
  if phase == nil then phase = 15 end
  if type(main) ~= [[function]] then main = function() end end

  -- Jail
  setfenv(0, env) -- global environment
  setfenv(1, env) -- bootstrap environment
  setfenv(main, env) -- script environment
  env._G = env
  env.env = env

  local phases = {
    -- 1. Seawolf libraries
    function ()      
      require [[seawolf.variable]]
      require [[seawolf.fs]]
      require [[seawolf.text]]
      require [[seawolf.behaviour]]
      require [[seawolf.contrib]]
    end,

    -- 2. Debug API
    function ()      
      if settings.debugapi then
        require [[includes.debug]]
      end
    end,

    -- 3. Build base URL
    function ()    
      base_root = (_SERVER [[HTTPS]] ~= nil and _SERVER [[HTTPS]] == [[on]]) and [[https]] or [[http]]
      base_root = base_root .. '://' .. (_SERVER [[HTTP_HOST]] or [[default]])
      base_url = base_root

      local dir = seawolf.text.trim(seawolf.fs.dirname(_SERVER [[SCRIPT_NAME]] or [[/index.cgi]]), [[\,/]])
      if dir ~= [[]] then
        base_path = [[/]] .. dir
        base_url = base_url .. base_path
        base_path = base_path .. [[/]]
      end
    end,

    -- 4. Mobile API,
    function ()    
      if settings.mobile then
        require [[includes.mobile]]
      end
    end,

    -- 5. CGI API,
    function ()
      cgic.init()
      require [[includes.cgi]]
    end,

    -- 6. Check installer
    function ()
      if (_SERVER [[SCRIPT_NAME]] or [[/index.cgi]]) == base_path .. [[index.cgi]] and not seawolf.fs.is_file [[settings.lua]] then
        header('location', ('%s%sinstall.cgi'):format(base_root, base_path))
        header('connection', 'close')
        io.write ''
        return -1
      end
    end,

    -- 7. Session API,
    function ()    
      if settings.sessionapi then
        require [[includes.session]]
        session_start()
      end
    end,

    -- 8. Path API,
    function ()    
      if seawolf.variable.empty(_GET.q) and settings.site then
        _GET.q = settings.site.frontpage
      end
      require [[includes.path]]
    end,

    -- 9. Core API,
    function ()
      require [[includes.common]]
      require [[includes.module]]
      require [[includes.theme]]
    end,
    
    -- 10. Modules,
    function ()
      local status, err

      for k, v in pairs(settings.modules) do
        if v then
          status, err = pcall(require, [[modules.]] .. k .. [[.init]])
          if not status then
            print([[bootstrap: ]] .. err)
          end
        end
      end
    end,

    -- 11. Boot,
    function ()
      module_invoke_all [[boot]]
    end,

    -- 12. Menu API,
    function ()
      require [[includes.menu]]
    end,

    -- 13. Database API,
    function ()
      if settings.db ~= nil then
        require [[includes.database]]
        if settings.db.default ~= nil then
          db_connect()
        end
      end
    end,

    -- 14. Init,
    function ()
      module_invoke_all [[init]]
    end,

    -- 15. Full,
    function ()
      -- call hook menu to load path handlers
      -- TODO: implement path cache
      ophal.paths = module_invoke_all [[menu]]

      -- process current path
      init_path()
    end,
  }

  -- Loop over phase
  local exit_bootstrap
  for p = 1, phase do
    if phases[p]() == -1 then
      exit_bootstrap = true
      break;
    end
  end

  -- execute script
  if not exit_bootstrap then
    status, err = pcall(main)
    if not status then
      print([[bootstrap: ]] .. (err or ''))
    end
  end

  -- call hook exit
  if module_invoke_all then
    module_invoke_all [[exit]]
  end

  -- destroy session (phase end)
  if settings.sessionapi then
    session_write_close()
  end

  -- CGI exit
  cgic.exit() -- free memory

  -- flush output buffer
  if settings.output_buffering then
    output_flush()
  end
end
