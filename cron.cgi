#!/usr/bin/env lua

require 'includes.bootstrap'

settings.output_buffering = false

ophal.bootstrap(nil, function ()
  if not settings.maintenance_mode then
    module_invoke_all 'cron'
  end
end)
