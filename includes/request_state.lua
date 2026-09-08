--[[ State that belongs to one request rather than to the worker.

  A worker runs one Lua VM and one coroutine per request, so every global and
  every file upvalue is shared by whatever requests are in flight at the same
  time. That has been safe only because a request has, until now, run from
  bootstrap to response without ever giving the worker up: the database driver
  is synchronous, so nothing yields, so nothing else runs in between.

  A non-blocking driver ends that. Every query becomes a yield point, and the
  request that resumes finds `_GET`, `_SESSION` and `base` describing whichever
  request ran while it was parked -- `ophal_request_reset()` rewrites all of
  them at the start of each one. `persistent_interleave` in the smoke suite is
  that failure, reproduced with `ngx.sleep` standing in for the query.

  `ngx.ctx` is per-request by construction, so state kept here is immune to it
  and needs no clearing between requests: a new request arrives with a new
  table. The CLI, the installer and the unit suite have no `ngx`, and they are
  one process per request, so a single table serves them.
]]

local M = {}

-- One key, so the rest of `ngx.ctx` stays available to anything else that
-- wants it.
local KEY = 'ophal'

local standalone

function M.current()
  local ctx

  if ngx == nil then
    if standalone == nil then
      standalone = {}
    end

    return standalone
  end

  ctx = ngx.ctx

  if ctx[KEY] == nil then
    ctx[KEY] = {}
  end

  return ctx[KEY]
end

-- Only the standalone runtimes need this; under nginx the next request brings
-- its own `ngx.ctx`. It is called from `ophal_request_reset()` all the same, so
-- that a persistent non-nginx runtime -- were there one -- would behave.
function M.reset()
  if ngx == nil then
    standalone = {}
  else
    ngx.ctx[KEY] = nil
  end
end

--[[ Names that describe the request rather than the site.

  A name maps to a function returning its value for a request that has not set
  one, or to `false` where an unset name is simply nil. Defaults are stored on
  first read, so `ophal.blocks` is the same table for the length of one request
  rather than a new one on every access.
]]
local REQUEST_GLOBALS = {
  _GET = function() return {} end,
  _SESSION = false,
  -- `base` is here because every one of its fields -- scheme, host, path --
  -- is derived from the request in `build_base()`.
  base = function()
    return {system_root = '', route = '/', url = '', path = ''}
  end,
  output_buffer = function() return {} end,
}

-- Fields of `ophal`. `modules`, `routes`, `aliases`, `redirects` and `version`
-- are absent on purpose: those are worker state, and the route tables are held
-- across requests deliberately.
local REQUEST_OPHAL = {
  blocks = function() return {} end,
  regions = function() return {} end,
  cookies = function() return {} end,
  raw_cookies = function() return '' end,
  header_title = false,
  request = false,
  session = false,
  title = false,
}

--[[ A metatable routing the declared names to the current request's state.

  `__index` and `__newindex` fire only for keys the table does not hold, so a
  declared name must never be rawset on it. That is why `includes/bootstrap.lua`
  removed these names from the `env` literal rather than leaving them there as
  defaults: one `base = {}` in the table would switch the routing off for every
  request, silently and completely.
]]
local function request_scoped(names, prefix, fallback)
  local keys = {}
  local fallback_is_function = type(fallback) == 'function'

  for name in pairs(names) do
    keys[name] = prefix and (prefix .. name) or name
  end

  return {
    __index = function(t, name)
      local key = keys[name]
      local state, value, default

      -- Anything not declared here is not request state, so it is whatever the
      -- table already chained to. Production installs this on a table with no
      -- metatable and `fallback` is nil; the unit suite chains its jailed
      -- environment to `_G` for stubs, and that has to keep working.
      if key == nil then
        if fallback_is_function then
          return fallback(t, name)
        elseif fallback ~= nil then
          return fallback[name]
        end

        return nil
      end

      state = M.current()
      value = state[key]

      if value == nil then
        default = names[name]
        if default then
          value = default()
          state[key] = value
        end
      end

      return value
    end,
    __newindex = function(t, name, value)
      local key = keys[name]

      if key == nil then
        rawset(t, name, value)
        return
      end

      M.current()[key] = value
    end,
  }
end

--[[ Split a jailed environment into worker state and request state.

  The names keep their spelling. `_SESSION`, `_GET`, `base.path`, `ophal.title`
  are read and written exactly as before; only where the value lives changes,
  which is why no module had to be touched for this.
]]
function M.install(env)
  local function chained(t, names, prefix)
    local existing = getmetatable(t)

    return request_scoped(names, prefix, existing and existing.__index)
  end

  setmetatable(env, chained(env, REQUEST_GLOBALS))
  setmetatable(env.ophal, chained(env.ophal, REQUEST_OPHAL, 'ophal.'))

  return env
end

return M
