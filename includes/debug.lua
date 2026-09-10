local temp_dir = require('includes.fs.path').temp_dir
local util = require 'includes.util'

--[[ A value rendered for a browser.

  This wrapped `seawolf.variable.print_r`, which printed rather than returned
  unless its second argument was truthy -- and decided truthiness with
  `empty()`, so `print_r(t, 0)` and `print_r(t, '')` printed. `util.dump()`
  always returns a string and this decides what to do with it.
]]
function debug.print_r(val, return_)
  local result = ('<pre>%s</pre>'):format(util.dump(val))

  if return_ then
    return result
  end

  print(result)
end

function debug.log(msg)
  if type(log_debug) == 'function' then
    return log_debug('debug log', {
      event = 'debug_log',
      value = debug.print_r(msg, 1),
    })
  end

  local fh = io.open(temp_dir() .. '/ophal.log', 'a+')
  if fh then
    return fh:write(("%s: %s\n"):format(os.date('%Y-%m-%d %H:%M:%S', os.time()), debug.print_r(msg, 1)))
  end
end
