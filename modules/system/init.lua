local _M = {}
ophal.modules.system = _M

local jobs = require 'includes.jobs'

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
