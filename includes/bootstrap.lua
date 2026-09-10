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
  xpcall = xpcall,
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
  theme = {},
  -- `base`, `output_buffer`, `_GET` and `_SESSION` are deliberately absent, and
  -- so are the request-scoped fields of `ophal`. They are routed to the current
  -- request's state below, and `__index` only fires for a key the table does
  -- not hold -- so listing them here as defaults would switch the routing off.
  ophal = {
    version = nil,
    modules = {},
    routes = {},
    aliases = {},
    redirects = {},
    header = nil,
  },
}

-- Build settings
settings = require('includes.settings_loader').build()

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

-- Detect OpenResty
if ngx then
  env.ngx = ngx
  env.pcall = env.nopcall
  for k, v in pairs(getfenv(0, ngx)) do
    env[k] = v
  end
end

-- Split the jailed environment into worker state and request state. Everything
-- above this point is the worker's; `_GET`, `_SESSION`, `base` and the
-- request-scoped fields of `ophal` belong to one request from here on.
require('includes.request_state').install(env)

-- The actual module
local setfenv, type, env = setfenv, type, env
module 'ophal'

function bootstrap(phase, main)
  if type(main) ~= 'function' then main = function() end end

  local status, err, exit_bootstrap
  local traceback

  -- Jail
  setfenv(0, env) -- global environment
  setfenv(1, env) -- bootstrap environment
  setfenv(main, env) -- script environment
  env._G = env
  env.env = env

  require 'includes.log'

  local function protected_call(callback)
    local raw_error

    if pcall == nopcall then
      return pcall(callback)
    end

    local function error_handler(e)
      raw_error = e
      if debug and type(debug.traceback) == 'function' then
        return debug.traceback(tostring(e), 2)
      end
      return tostring(e)
    end

    local ok, result = xpcall(callback, error_handler)
    if ok then
      return true, result
    end

    return false, raw_error or result, result
  end

  -- Reset per-request state for persistent runtimes.
  -- On first boot ophal_request_reset does not exist yet; on subsequent
  -- requests in a persistent VM it clears stale globals and closure locals.
  if type(ophal_request_reset) == 'function' then
    ophal_request_reset()
  end

  local phases = {
    --[[ 1. Lua libraries.

      `lfs` is the only one left. `uuid` and `seawolf` were required here, and
      `seawolf` is what pulled `lpeg` and `socket` in behind it -- its `fs`
      component requires `socket.sleep` and `uuid` at load, for a lock spin
      `includes/session/store.lua` no longer performs.
    ]]
    function ()
      env.lfs = require 'lfs'
    end,

    -- 2. Debug API
    function ()
      if settings.debugapi then
        require 'includes.debug'
      end
    end,

    -- 3. Load native server API
    function ()
      if not ngx then
        error('Ophal now requires OpenResty; CGI support has been removed')
      end
      require 'includes.server.adapter'
      require 'includes.server.openresty'
    end,

    -- 4. Load Ophal server API
    function ()
      require 'includes.server.init'
      build_base()
    end,

    -- 5. Check installer
    function ()
      if not require('includes.fs.path').is_file 'settings.lua' then
        header('status', '503 Service Unavailable')
        header('content-type', 'text/plain; charset=utf-8')
        print("Ophal is not installed.\nRun './ophal install init' from the project root.")
        return -1
      end
    end,

    -- 6. Session API,
    function ()
      local empty = require('includes.util').empty
      if not empty(settings.sessionapi) then
        require 'includes.session'
        session_start()
      end
    end,

    -- 7. Route API,
    function ()
      require 'includes.route'
    end,

    -- 8. Core API,
    function ()
      require 'includes.escape'
      require 'includes.common'
      require 'includes.security'
      require 'includes.locale'
      require 'includes.module'
      require 'includes.theme'
      require 'includes.pager'
      require 'includes.cache'
      if settings.formapi then
        require 'includes.form'
      end
    end,

    -- 9. Modules,
    function ()
      module_load_all()
    end,

    -- 10. Boot,
    function ()
      module_invoke_all 'boot'
    end,

    -- 11. Database API,
    --
    -- Nothing connects here. `db_connection()` resolves an object and opens a
    -- socket on the first statement run through it, so a request that reads
    -- everything it needs from a projection cache opens no connection at all --
    -- which is where the last two queries on a warm anonymous page went.
    function ()
      if settings.db ~= nil then
        require 'includes.database.init'
        if settings.db.default ~= nil then
          if settings.route_aliases_storage then
            route_aliases_load()
          end
          if settings.route_redirects_storage then
            route_redirects_load()
          end
        end
      end
    end,

    -- 12. Init,
    function ()
      route_redirect()
      module_invoke_all 'init'
    end,

    -- 13. Full,
    function ()
      -- Use cached routes when available (persistent runtimes);
      -- fall back to building fresh routes on cold start or after cache_clear_all().
      ophal.routes = route_cache_get() or route_build_routes()

      theme_blocks_load()
      theme_regions_load()

      -- process current route
      init_route()
    end,
  }

  -- Loop over phase
  for p = 1, (phase or #phases) do
    status, err, traceback = protected_call(phases[p])
    if not status then
      log_exception('bootstrap phase failed', err, {
        event = 'bootstrap_phase_failed',
        phase = p,
        traceback = (settings.logging or settings.log or {}).tracebacks == true and traceback or nil,
      })
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
    status, err, traceback = protected_call(main)
    if not status then
      log_exception('main callback failed', err, {
        event = 'main_callback_failed',
        traceback = (settings.logging or settings.log or {}).tracebacks == true and traceback or nil,
      })
      io.write([[

bootstrap[main]: ]] .. (err or ''))
    end
  end

  -- The end
  if type(exit_ophal) == 'function' then
    return exit_ophal()
  end

  -- Early bootstrap failures can happen before server/init defines exit_ophal.
  return
end
