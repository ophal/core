local print, echo, settings, _GET = print, echo, settings, _GET
local output_clean, output_get_clean = output_clean, output_get_clean
local io, os, fs, lfs = io, os, seawolf.fs, require [[lfs]]
local print_r, require = seawolf.variable.print_r, require

module [[ophal.modules.lorem_ipsum]]

--[[
  Return cache file path for current page.
]]
local function filepath()
  return ([[%s%s.html]]):format(settings.boost.path, _GET.q:gsub([[/]], [[_]]):gsub([[.]], [[_]]))
end

--[[
  Implementation of hook_boot()
]]
function boot()
  local file

  if settings.output_buffering then
    file = filepath()
    if fs.is_file(file) and not has_expired(file) then
      output_clean()
      io.input(file)
      print(io.read([[*all]]))
      os.exit()
    end
  end
end

--[[
  Given a timestamp, return formatted date by Boost format date.
]]
function format_date(ts)
  return os.date(settings.boost.date_format, ts)
end

--[[
  Given a timestamp, return cache signature.
]]
function signature()
  local ts = os.time()
  local created = format_date(ts)
  local expires = format_date(ts + settings.boost.lifetime)
  return (settings.boost.signature):format(created, expires)
end

--[[
  Given a file path, return cache expiration status.
]]
function has_expired(file)
  local ts = lfs.attributes(file, [[modification]])
  io.write(ts)
  if ts + settings.boost.lifetime <= os.time() then
    os.remove(file)
    return true
  end
end

--[[
  Implementation of hook_exit().
]]
function exit()
  local file, output, fh

  if settings.output_buffering then
    file = filepath()
    if not fs.is_file(file) then
      lfs.mkdir(settings.boost.path) -- force create file cache directory
      output = output_get_clean()
      if fs.is_dir(settings.boost.path) then
        -- Store output to cache
        fh = io.open(file, [[w+]])
        fh:write(output)
        -- Append signature
        if settings.boost.signature ~= nil then
          fh:write(signature())
        end
        fh:close()
      end
      -- Display output, wether it is in cache or not.
      print(output)
    end
  end
end
