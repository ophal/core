local _M = {}
ophal.modules.system = _M

local jobs = require 'includes.jobs'
local projection = require 'includes.projection'

--[[ The handler for every deferred projection rebuild.

  One kind covers all of them because the queue carries a projection key and
  `projection.run_rebuild()` looks the rebuild up in the registry each module
  fills at load time. Registering here rather than in `includes/projection.lua`
  keeps the queue out of that module's load-time dependencies -- `includes/jobs`
  requires it, so the arrow only points one way.
]]
jobs.register('projection_rebuild', function(payload)
  return projection.run_rebuild((payload or {}).projection)
end)

function _M.cron()
  session_destroy_expired()

  -- The drain is deliberately last and deliberately silent. `jobs.drain()`
  -- returns nothing at all, and this line discards what it gets: `system` runs
  -- first, and `module_invoke_all()` abandons every module it has not reached
  -- yet when a hook returns an error, so a broken queue must not be able to
  -- cancel session cleanup or anything a later module schedules. Failures are
  -- logged inside `drain()` rather than propagated here.
  jobs.drain()
end

return _M
