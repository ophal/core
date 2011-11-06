local slash, theme_name = settings.slash, settings.theme
local pcall, settings = pcall, settings
local table, assert, error, setfenv = table, assert, error, setfenv
local currentdir = lfs.currentdir() .. slash
local base_path = base_path

--[[
  Render theme template.
]]
local function theme_render(f, arg)
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
    arg.print = print
    arg.settings = settings
    arg.echo = echo
    arg.base_path = base_path
    arg.theme = theme
    arg.print_t = print_t
    arg.print_f = print_f
    setfenv(prog, arg)

    -- execute
    local status, result = pcall(prog)
    if status then
      return [[]] -- TODO: return a buffered output of the template
    else
      return ([[template '%s': %s]]):format(file, result)
    end
  end
end

--[[
  Execute theme function.
]]
local function theme_execute(f, ...)
  local arg = {...}

  local status, result = pcall(theme[f], unpack(arg))
  if status then
    return result
  else
    return ([[theme function %s: '%s']]):format(f, result)
  end
end

--[[
  Theme metatable.
]]
setmetatable(theme, {
  __call = function(t, arg)
    if not arg then arg = {} end

    local f = arg[1]

    if t[f] == nil then
      arg[1] = nil -- clean-up theme environment
      return theme_render(f, arg)
    else
      return theme_execute(unpack(arg))
    end
  end
})

--[[
  Translate given table key-value pairs to attr="value". 
]]
function render_attributes(options)
  if type(options) ~= [[table]] then return [[]] end

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

--[[
  Anchor theme function.
]]
function theme.a(path, text, options)
  return ([[<a href="%s%s" %s>%s</a>]]):format(base_path, path or [[]], render_attributes(options), text or [[]])
end

--[[
  Image theme function.
]]
function theme.img(path, options)
  return ([[<img src="%s%s" %s />]]):format(base_path, path or [[]], render_attributes(options))
end
