local print_r = seawolf.variable.print_r

--[[
  Wrapper of function print_r() from Nutria Seawolf.
]]
function debug.print_r(val, return_)
  local result = ([[<pre>%s</pre>]]):format(seawolf.variable.print_r(val, true))

  if return_ then
    return result
  end

  print(result)
end
