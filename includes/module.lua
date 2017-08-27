local xtable = seawolf.contrib.seawolf_table

do
  local mt = {
    register = function(t, module_name, module_definition)
      ophal.modules[module_name] = module_definition
    end
  }
  mt.__index = function(t, k)
    if mt[k] ~= nil then
      return mt[k]
    end
  end
  setmetatable(ophal.modules, mt)
end

do
  local order, group
  local list = xtable{'system'}

  --[[ Return the a list of modules by weight and name
  ]]
  function module_list()
    if nil == order then
      local rawset = rawset

      order, group = xtable(), xtable()

      -- Force system module to stay first ALWAYS
      settings.modules.system = nil

      -- Group modules by their weight
      for name, weight in pairs(settings.modules) do
        -- Ignore disabled modules
        if weight == false then return end

        if weight == true then
          weight = 1
        end

        if nil == group[weight] then
          rawset(group, weight, xtable{name})
          order:append(weight)
        else
          group[weight]:append(name)
        end
      end

      -- Sort weights
      order:sort()

      -- Build list of module names
      for k, weight in pairs(order) do
        -- Sort alphabetically
        group[weight]:sort()
        -- Add modules in current group to the list of names
        for j, name in pairs(group[weight]) do
          list:append(name)
        end
      end
    end

    return list
  end
end

function module_invoke_all(hook, ...)
  local err
  local result, r = {}

  for _, name in pairs(module_list()) do
    local m = ophal.modules[name]
    if m[hook] then
      r, err = m[hook](...) -- call hook implementation
      if err then
        return nil, err
      end
      if type(r) == 'table' then
        for k, v in pairs(r) do
          v.module = name -- register module name
          result[k] = v
        end
      elseif r then
        table.insert(result, r)
      end
    end
  end

  return result
end

function module_load(name)
  local status, err = pcall(require, 'modules.' .. name .. '.init')
  if not status then
    print('bootstrap: ' .. err)
  end
end

function module_load_all()
  for _, name in pairs(module_list()) do
    module_load(name)
  end
end
