local module_invoke_all, empty, l = module_invoke_all, seawolf.variable.empty, l
local tconcat, tinsert, theme, pairs = table.concat, table.insert, theme, pairs
local type, tsort = type, table.sort

local debug = debug

module 'ophal.modules.menu'

local menus = {
  primary_links = {
  }
}

local menus_build

function get_menus(reset)
  if reset then
    menus_build = false
  end

  if not menus_build then
    module_invoke_all('menus_alter', menus)
    menus_build = true
  end

  return menus
end

function theme.menu(variables)
  local menu_id = variables.id
  local menu = get_menus()[menu_id] or {}

  local items = {}
  for path, v in pairs(menu) do
    if type(v) ~= 'table' then
      v = {v}
    end
    if v.weight == nil then
      v.weight = 0
    end

    local label, options
    label = v[1]
    v[1] = nil
    options = v

    tinsert(items, {l(label, path, options), weight = v.weight})
  end

  tsort(items, function (a, b)
    return a.weight < b.weight
  end)

  return
    '<nav id="menu_' .. menu_id  .. '">' ..
    (function (items)
      local output = {}
      for k, v in pairs(items) do
        tinsert(output, v[1])
      end
      return tconcat(output, ' | ')
    end)(items) .. 
    '</nav>'
end
