local theme_name
local slash = settings.slash
local pcall, settings = pcall, settings
local table, assert, error, setfenv = table, assert, error, setfenv
local currentdir = lfs.currentdir() .. slash
local base_path, l = base_path, l

if
  settings.mobile and
  (mobile.detect.isMobile() or _SERVER [[HTTP_HOST]] == settings.mobile.domain_name)
then
  theme_name = settings.mobile.theme
else
  theme_name = settings.theme
end

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
    arg.mobile = mobile
    arg.print_t = print_t
    arg.print_f = print_f
    arg.debug = debug
    arg.l = l
    arg.path_to_theme = path_to_theme
    arg.pairs = pairs
    arg._SERVER = _SERVER
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
function render_attributes(options, default_options)
  if default_options == nil then default_options = {} end

  -- Merge default_options into options
  if type(options) ~= [[table]] then
    options = default_options
  else
    for k, v in pairs(default_options) do
      if options[k] == nil then
        options[k] = default_options[k]
      end
    end
  end

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

function path_to_theme()
  return ([[themes/%s]]):format(theme_name)
end

--[[
  Anchor theme function.
]]
function theme.a(variables)
  return ([[<a href="%s" %s>%s</a>]]):format(variables.path, render_attributes(variables.attributes), variables.text)
end

--[[
  Image theme function.
]]
function theme.img(path, options)
  path = path or [[]]
  if options and options.external then
    options.external = nil
  else
    path = base_path .. path
  end
  return ([[<img src="%s" %s />]]):format(path, render_attributes(options))
end

--[[
  Logo theme function.
]]
function theme.logo()
  local site = settings.site
  local logo_path = ([[%s/%s]]):format(path_to_theme(), site.logo_path)
  return l(theme{[[img]], logo_path, {alt = site.logo_title, title = site.logo_title, border = 0}}, [[]], {attributes = {id = [[logo]]}})
end
