#!/usr/bin/env lua5.1

require 'includes.bootstrap'

ophal.bootstrap(nil, function ()
  route_execute_active_handler()
end)
