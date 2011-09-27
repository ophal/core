local print_r = seawolf.variable.print_r

--[[
  Output given value using seawolf's print_r().
]]
function debug.print_r(val)
  print(([[<pre>%s</pre>]]):format(seawolf.variable.print_r(val,1)))
end