#!/usr/bin/env luajit

require [[includes.bootstrap]]

ophal.bootstrap(function ()
  if not settings.maintenance_mode then
    module_invoke_all [[cron]]
  end
end)
