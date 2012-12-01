#!/usr/bin/env luajit

require [[includes.bootstrap]]

ophal.bootstrap(nil, function ()
  menu_execute_active_handler()
end)
