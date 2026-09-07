require 'includes.bootstrap'

settings.output_buffering = false

ophal.bootstrap(nil, function ()
  -- The gate is checked after bootstrap rather than before it because
  -- `cron_access()` is defined inside the jailed environment bootstrap builds.
  -- A refused request therefore still pays for a bootstrap, the same as any
  -- other request that reaches Lua; what it does not pay for is the queue
  -- drain, which is the unbounded part.
  if cron_access() then
    if not settings.maintenance_mode then
      module_invoke_all 'cron'
    end
  else
    cron_denied()
  end

  -- Output something to prevent error 500
  print ''
end)
