function module_invoke_all(hook, ...)
  local err
  local result, r = {}

  for name, m in pairs(ophal.modules) do
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
  local xtable = seawolf.contrib.seawolf_table

  -- Always load the system module first
  module_load 'system'
  settings.modules.system = nil

  -- Sort by weight
  local order = xtable{keys = xtable()}
  xtable(settings.modules):each(function (k, v)
    -- Ignore disabled modules
    if v == false then return end

    if v == true then
      v = 1
    end

    if order[v] == nil then
      order[v] = xtable{k}
      order.keys:append(v)
    else
      order[v]:append(k)
    end
  end)
  order.keys:sort()

  for _, o in pairs(order.keys) do
    local modules = order[o]
    modules:sort() -- Sort alphabetically
    modules:each(function (k, v)
      module_load(v)
    end)
  end
end
