#!/usr/bin/env luajit

print [[X-Powered-By: Ophal/0.1-alpha4
Content-type: text/html; charset=utf-8
]]

function main()
  theme [[html]]
end

require [[includes.bootstrap]]

ophal.bootstrap()

main()
