local slash, tinsert, tconcat = settings.slash, table.insert, table.concat
local pcall, settings, empty = pcall, settings, seawolf.variable.empty
local assert, error, setfenv = assert, error, setfenv
local currentdir, xtable = lfs.currentdir() .. slash, seawolf.contrib.seawolf_table
local base, l = base, l

-- Calculate theme.name
if
  settings.mobile and
  (mobile.detect.isMobile() or _SERVER 'HTTP_HOST' == settings.mobile.domain_name)
then
  theme.name = settings.mobile.theme
else
  if type(settings.theme) == 'table' then
    theme.name = settings.theme.name
  else
    theme.name = settings.theme
  end
end

-- Load themes/%/settings.lua
local seawolf = require 'seawolf'.__build('variable', 'contrib')

if settings.template_env == nil then settings.template_env = {} end

if settings.theme == nil then settings.theme = {name = 'basic'} end
do
  local mt = {}
  mt.__index = function(t, k)
    if mt[k] ~= nil then
      return mt[k]
    end
  end
  mt.override = function(t, vars)
    if t.__overrides == nil then
      t.__overrides = {}
    end
    t.__overrides[vars[1]] = vars[2]
  end
  setmetatable(settings.theme, mt)
end

if settings.theme.css == nil then settings.theme.css = {} end
setmetatable(settings.theme.css, seawolf.contrib.metahelper)

if settings.theme.js == nil then settings.theme.js = {} end
setmetatable(settings.theme.js, seawolf.contrib.metahelper)

local _, settings_builder = pcall(require, ('themes.%s.settings'):format(settings.theme.name))
if type(settings_builder) == 'function' then
  settings_builder(settings.theme, settings.template_env)
end

-- Set final theme settings
theme.settings = settings.theme

init_head()
init_css()
init_js()

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
  file = ('%sthemes%s%s%s%s.tpl.html'):format(currentdir, slash, theme.name, slash, f)

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
    src = src:gsub('(<%?lua)(.-)(%?>)', "]]; %2 print[[")

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
    local buffer = {}
    if env._return then
      env.print = function (v) buffer[1 + #buffer] = v end
    else
      env.print = theme_print
    end
    env.settings = settings
    env.echo = echo
    env.base = base
    env.theme = theme
    env.mobile = mobile
    env.print_t = print_t
    env.print_f = print_f
    env.debug = debug
    env.l = l
    env.route_arg = route_arg
    env.request_path = request_path
    env.path_to_theme = path_to_theme
    env.pairs = pairs
    env.format_date = format_date
    env._SERVER = _SERVER
    env.mobile = mobile
    env.core_version = ophal.version
    setfenv(prog, env)

    -- execute
    local status, result = pcall(prog)
    if status then
      return tconcat(buffer)
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
  Call theme function
]]
local function theme_call(t, arg)
  if not arg then arg = {} end

  local f = arg[1]

  arg[1] = nil -- clean-up theme environment

  -- Let modules alter theme function arguments
  module_invoke_all('theme_preprocess', f, arg)

  if t[f] == nil then
    return theme_render(f, arg)
  else
    return theme_execute(f, arg)
  end
end

--[[
  Theme metatable
]]
local mt = {
  __call = function(t, arg)
    local meta = getmetatable(t)
    local overrides = settings.theme.__overrides or {}

    -- Override theme functions
    for k in pairs(overrides) do
      if (overrides and type(overrides) == 'table') then
        local orig = t[k]
        t[k] = function(...)
          return overrides[k](..., orig, theme)
        end
      end
    end

    meta.__call = theme_call
    return meta.__call(t, arg)
  end,
}

setmetatable(theme, mt)

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
  Translate given table key-value pairs to "val1 val2".
]]
function render_classes(classes, default_classes)
  if default_classes == nil then default_classes = {} end

  if type(classes) ~= 'table' then
    classes = default_classes
  else
    for k, v in pairs(default_classes) do
      if classes[k] == nil and not empty(classes[k]) then
        classes[k] = default_classes[k]
      end
    end
  end

  local output = {}

  for k, _ in pairs(classes) do
    tinsert(output, k)
  end
  return tconcat(output, '')
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

--[[
  Return the output of given theme function and parameters.
]]
function render_t(arg)
  arg._return = true
  return theme(arg)
end

function theme.json(variables)
  local json = require 'dkjson'
  local content = variables.content

  if not variables.status then
    content = {error = content}
  end

  local output = json.encode(content)

  header('content-type', 'application/json; charset=utf-8')
  header('content-length', (output or ''):len())

  theme_print(output)
end

function path_to_theme()
  return ('themes/%s'):format(theme.name)
end

function theme_blocks_load()
  module_invoke_all('blocks_alter', ophal.blocks)
end

function theme_regions_load()
  ophal.regions = module_invoke_all('region')

  -- Default regions
  ophal.regions.sidebar_first = {
    id = 'sidebar_first',
    blocks = xtable(),
  }
  ophal.regions.sidebar_last = {
    id = 'sidebar_last',
    blocks = xtable(),
  }

  module_invoke_all('regions_alter', ophal.regions)
end

function theme_get_regions()
  local output = {}

  for _, region in pairs(ophal.regions) do
    if not empty(region) then
      local region_output = {}
      for _, block in pairs(region.blocks) do
        if block.id and not empty(ophal.blocks[block.id]) then
          block = ophal.blocks[block.id]
          region_output[#region_output + 1] = function ()
            theme{'block', entity = block}
          end
        end
      end

      -- Delayed rendering, this function will be called on theme render
      output[region.id] = function ()
        for k, v in pairs(region_output) do
          v()
        end
      end
    end
  end

  return output
end

--[[
  Anchor theme function.
]]
function theme.a(variables)
  if variables == nil then variables = {} end

  local attributes = variables.attributes
  variables.attributes = nil

  -- Support HTML5 download attribute
  local download = attributes.download
  attributes.download = nil
  if download == true then
    download = ' download'
  elseif type(download) == 'string' then
    download = (' download="%s"'):format(download)
  end

  return ('<a href="%s"%s %s>%s</a>'):format(variables.route, download or '', render_attributes(attributes), variables.text)
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
    path = base.route .. path
  end
  return ('<img src="%s" %s />'):format(path, render_attributes(options))
end

--[[
  Logo theme function.
]]
function theme.logo()
  local site = settings.site
  local logo_path = ('%s/%s'):format(path_to_theme(), site.logo_path)
  return l(theme{'img', path = logo_path, options = {alt = site.logo_title, title = site.logo_title, border = 0}}, '', {absolute = true, attributes = {id = 'logo'}})
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
