local xtable = seawolf.contrib.seawolf_table
local tinsert = table.insert

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

--[[ Load optional info.lua metadata for a module.
  Falls back to synthesized metadata when the file is absent.
]]
function module_load_info(name)
  local ok, info = pcall(require, 'modules.' .. name .. '.info')
  if ok and type(info) == 'table' then
    info.name = info.name or name
    info.dependencies = info.dependencies or {}
    info.weight = info.weight or 1
    info.capabilities = info.capabilities or {}
    return info
  end
  -- Synthesize from settings
  local w = settings.modules[name]
  if w == true or type(w) ~= 'number' then
    w = 1
  end
  return {
    name = name,
    dependencies = {},
    weight = w,
    capabilities = {},
  }
end

-- Insert name into a sorted ready queue by (weight asc, name asc).
local function insert_sorted(queue, name, infos)
  local w = infos[name].weight
  for i = 1, #queue do
    local qw = infos[queue[i]].weight
    if w < qw or (w == qw and name < queue[i]) then
      tinsert(queue, i, name)
      return
    end
  end
  queue[#queue + 1] = name
end

--[[ Resolve module load order via topological sort.
  Uses Kahn's algorithm with weight/name tie-breaking.
  system is unconditionally first.
]]
function module_resolve_order(enabled)
  local infos = {}
  local valid = {}
  for _, name in ipairs(enabled) do
    infos[name] = module_load_info(name)
    valid[name] = true
  end

  -- Build adjacency list and in-degree counts
  local adj = {}
  local in_deg = {}
  for _, name in ipairs(enabled) do
    adj[name] = adj[name] or {}
    in_deg[name] = in_deg[name] or 0
    for _, dep in ipairs(infos[name].dependencies) do
      if valid[dep] then
        adj[dep] = adj[dep] or {}
        adj[dep][#adj[dep] + 1] = name
        in_deg[name] = in_deg[name] + 1
      end
    end
  end

  -- Start output with system
  local output = xtable{'system'}
  in_deg['system'] = -1 -- mark processed

  -- Release dependents of system
  for _, dependent in ipairs(adj['system'] or {}) do
    in_deg[dependent] = in_deg[dependent] - 1
  end

  -- Seed ready queue with zero-in-degree modules (excluding system)
  local ready = {}
  for _, name in ipairs(enabled) do
    if name ~= 'system' and in_deg[name] == 0 then
      insert_sorted(ready, name, infos)
    end
  end

  -- Process ready queue
  while #ready > 0 do
    local name = table.remove(ready, 1)
    output:append(name)
    for _, dependent in ipairs(adj[name] or {}) do
      in_deg[dependent] = in_deg[dependent] - 1
      if in_deg[dependent] == 0 then
        insert_sorted(ready, dependent, infos)
      end
    end
  end

  -- Cycle fallback
  if #output ~= #enabled then
    io.stderr:write('module: dependency cycle detected; falling back to weight order for remaining modules\n')
    for _, name in ipairs(enabled) do
      if in_deg[name] and in_deg[name] > 0 then
        output:append(name)
      end
    end
  end

  return output
end

do
  local list

  --[[ Return the list of active modules in resolved order.
    Result is cached after the first call.
  ]]
  function module_list()
    if nil == list then
      -- Force system module to stay first ALWAYS
      settings.modules.system = nil

      -- Collect enabled module names
      local enabled = xtable{'system'}
      for name, weight in pairs(settings.modules) do
        if weight ~= false then
          enabled:append(name)
        end
      end

      list = module_resolve_order(enabled)
    end

    return list
  end
end

function module_invoke_all(hook, ...)
  local err
  local result, r = {}

  for _, name in pairs(module_list()) do
    local m = ophal.modules[name]
    if m and m[hook] then
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
    error('module: ' .. err)
  end
end

function module_load_all()
  for _, name in pairs(module_list()) do
    module_load(name)
  end
end
