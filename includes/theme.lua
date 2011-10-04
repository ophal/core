local slash, theme_name = settings.slash, settings.theme
local pcall, settings, cursrentdir = pcall, settings, lfs.currentdir
local table, assert, error, setfenv = table, assert, error, setfenv
local currentdir = lfs.currentdir() .. slash
local base_path = base_path

setmetatable(theme, {
  __call = function(t, f, args)
    if not args then args = {} end
    if t[f] == nil then
      file = ([[%sthemes%s%s%s%s.tpl.html]]):format(currentdir, slash, theme_name, slash, f)

      local attr, err = lfs.attributes(file)
      if err then
        return ([[template '%s': %s]]):format(file, err)
      end

      if attr ~= nil and attr.mode == [[file]] then
        -- read file contents
        local fh = assert(io.open(file))
        local src = ('print [[%s]]'):format(fh:read([[*a]]))
        fh:close()

        -- translate lua template tag
        src = src:gsub([[(<%?lua)(.-)(%?>)]], "]]; %2print[[")

        -- load source code
        local prog, err = loadstring(src, file)
        if not prog then
          return ([[template '%s': %s]]):format(file, err)
        end

        -- jail
        args = args or {}
        args.print = print
        args.settings = settings
        args.echo = echo
        args.base_path = base_path
        args.theme = theme
        args.print_t = print_t
        args.print_f = print_f
        setfenv(prog, args)

        -- execute
        local status, result = pcall(prog)
        if status then
          return [[]] -- TODO: return a buffered output of the template
        else
          return ([[template '%s': %s]]):format(file, result)
        end
      end
    else
      -- execute
      local status, result = pcall(t[f], unpack(args))
      if status then
        return result
      else
        return ([[theme function %s: '%s']]):format(f, result)
      end
    end
  end
})

--[[
  Translate given table key-value pairs to attr="value". 
]]
function parse_attributes(options)
  if type(options) ~= [[table]] then options = {} end

  local attr = {}

  for k, v in pairs(options) do
    table.insert(attr, ([[%s="%s"]]):format(k, v))
  end
  return table.concat(attr, " ")
end

--[[
  Print output of given theme function and parameters.
]]
function print_t(...)
  print(theme(...))
end

--[[
  Print output of given theme function and parameters.
]]
function print_f(text, ...)
  print(text:format(...))
end

function theme.a(path, text, options)
  if type(options) ~= [[table]] then options = {} end

  return ([[<a href="%s%s" %s>%s</a>]]):format(base_path, path, parse_attributes(options), text)
end

