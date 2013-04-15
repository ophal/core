local theme_name
local slash, tinsert, tconcat = settings.slash, table.insert, table.concat
local pcall, settings, empty = pcall, settings, seawolf.variable.empty
local assert, error, setfenv = assert, error, setfenv
local currentdir = lfs.currentdir() .. slash
local base_path, l = base_path, l

if
  settings.mobile and
  (mobile.detect.isMobile() or _SERVER 'HTTP_HOST' == settings.mobile.domain_name)
then
  theme_name = settings.mobile.theme
else
  theme_name = settings.theme
end

function theme_print(v)
  if type(v) == 'function' then
    v()
  else
    return print(v)
  end
end

--[[
  Render theme template.
]]
local function theme_render(f, env)
  file = ('%sthemes%s%s%s%s.tpl.html'):format(currentdir, slash, theme_name, slash, f)

  local attr, err = lfs.attributes(file)
  if err then
    return ("template '%s': %s"):format(file, err)
  end

  if attr ~= nil and attr.mode == 'file' then
    -- read file contents
    local fh = assert(io.open(file))
    local src = ('print [[%s]]'):format(fh:read('*a'))
    fh:close()

    -- translate lua template tag
    src = src:gsub('(<%?lua)(.-)(%?>)', "]]; %2print[[")

    -- load source code
    local prog, err = loadstring(src, file)
    if not prog then
      return ("template '%s': %s"):format(file, err)
    end

    -- extend env
    if not empty(settings.template_env) then
      for k, v in pairs(settings.template_env) do
        if env[k] == nil then
          env[k] = v
        end
      end
    end

    -- jail
    env.print = theme_print
    env.settings = settings
    env.echo = echo
    env.base_path = base_path
    env.theme = theme
    env.mobile = mobile
    env.print_t = print_t
    env.print_f = print_f
    env.debug = debug
    env.l = l
    env.arg = arg
    env.path_to_theme = path_to_theme
    env.pairs = pairs
    env._SERVER = _SERVER
    env.mobile = mobile
    setfenv(prog, env)

    -- execute
    local status, result = pcall(prog)
    if status then
      return '' -- TODO: return a buffered output of the template
    else
      return ("template '%s': %s"):format(file, result)
    end
  end
end

--[[
  Execute theme function.
]]
local function theme_execute(f, arg)
  local status, result = pcall(theme[f], arg)
  if status then
    if type(result) == 'function' then
      status, result = pcall(result)
      if status then
        return result
      end
    else
      return result
    end
  end
  return ("theme function %s: '%s'"):format(f, result)
end

--[[
  Theme metatable.
]]
setmetatable(theme, {
  __call = function(t, arg)
    if not arg then arg = {} end

    local f = arg[1]

    arg[1] = nil -- clean-up theme environment

    if t[f] == nil then
      return theme_render(f, arg)
    else
      return theme_execute(f, arg)
    end
  end
})

--[[
  Translate given table key-value pairs to attr="value". 
]]
function render_attributes(options, default_options)
  if default_options == nil then default_options = {} end

  -- Merge default_options into options
  if type(options) ~= 'table' then
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
    tinsert(attr, ('%s="%s"'):format(k, v))
  end
  return tconcat(attr, " ")
end

--[[
  Print output of given theme function and parameters.
]]
function print_t(...)
  print(theme(...) or '')
end

--[[
  Print output of given theme function and parameters.
]]
function print_f(text, ...)
  print(text:format(...))
end

function path_to_theme()
  return ('themes/%s'):format(theme_name)
end

--[[
  Anchor theme function.
]]
function theme.a(variables)
  return ('<a href="%s" %s>%s</a>'):format(variables.path, render_attributes(variables.attributes), variables.text)
end

--[[
  Image theme function.
]]
function theme.img(variables)
  local path = variables.path or ''
  local options = variables.options

  if options and options.external then
    options.external = nil
  else
    path = base_path .. path
  end
  return ('<img src="%s" %s />'):format(path, render_attributes(options))
end

--[[
  Logo theme function.
]]
function theme.logo()
  local site = settings.site
  local logo_path = ('%s/%s'):format(path_to_theme(), site.logo_path)
  return l(theme{'img', path = logo_path, options = {alt = site.logo_title, title = site.logo_title, border = 0}}, '', {attributes = {id = 'logo'}})
end

--[[
  Items list function theme function.
]]
function theme.item_list(variables)
  if variables == nil then variables = {} end

  local list = variables.list
  variables.list = nil

  local output = {('<ul%s>'):format(list ~= nil and ' ' .. render_attributes(variables) or '')}
  for _, v in pairs(list) do
    tinsert(output, ('<li>%s</li>'):format(v))
  end
  tinsert(output, '</ul>')
  return tconcat(output)
end
