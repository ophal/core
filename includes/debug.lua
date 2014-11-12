local print_r = seawolf.variable.print_r
local temp_dir = seawolf.behaviour.temp_dir

--[[
  Wrapper of function print_r() from Nutria Seawolf.
]]
function debug.print_r(val, return_)
  local result = ('<pre>%s</pre>'):format(seawolf.variable.print_r(val, true))

  if return_ then
    return result
  end

  print(result)
end

function debug.log(msg)
  local fh = io.open(temp_dir() .. '/ophal.log', 'a+')
  if fh then
    return fh:write(("%s: %s\n"):format(os.date('%Y-%m-%d %H:%M:%S', os.time()), debug.print_r(msg, 1)))
  end
end
