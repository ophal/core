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
  local output = {'system'}
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
    output[#output + 1] = name
    for _, dependent in ipairs(adj[name] or {}) do
      in_deg[dependent] = in_deg[dependent] - 1
      if in_deg[dependent] == 0 then
        insert_sorted(ready, dependent, infos)
      end
    end
  end

  -- Cycle fallback
  if #output ~= #enabled then
    if type(log_warn) == 'function' then
      log_warn('module dependency cycle detected; falling back to weight order for remaining modules', {
        event = 'module_dependency_cycle',
      })
    else
      io.stderr:write('module: dependency cycle detected; falling back to weight order for remaining modules\n')
    end
    for _, name in ipairs(enabled) do
      if in_deg[name] and in_deg[name] > 0 then
        output[#output + 1] = name
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
      local enabled = {'system'}
      for name, weight in pairs(settings.modules) do
        if weight ~= false then
          enabled[#enabled + 1] = name
        end
      end

      list = module_resolve_order(enabled)
    end

    return list
  end

  function module_cache_clear()
    list = nil
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

--[[ Seal a jailed module's table once it has finished loading.

  A file that calls `module()` has the module table as its environment, so an
  unqualified assignment inside one of its functions does not create a local --
  it creates a **field on the module table**, which the worker keeps and the
  next request can read. This project has paid for that six times:
  `modules/user`'s `_SESSION`, `modules/file`'s `entity`, `modules/comment`'s
  `comment` and then its `list`, the `os.rename`/`type`/`_GET` captures in
  Phase 6, `modules/lorem_ipsum`'s `html_safe`, and the route table `items` in
  three modules at once. Each was found by reading, one at a time, after
  the maintainer log had already written down the rule five times.

  `module()` is the funnel, so the guard goes here rather than in a linter.
  `__newindex` fires only for keys a table does not already hold, and by the
  time loading is done the table holds exactly the module's declared surface --
  so "undeclared" needs no whitelist and cannot drift out of step with the
  code. It is whatever the file itself defined.

  Writes only. A strict `__index` would also catch an undeclared *read* -- the
  bare `comment` that `fetch_service` passed to `comment_access` for years --
  but `module_invoke_all()` below probes `m[hook]` for every module and every
  hook, and `modules/entity` probes `entity_class[fn]`, so raising on a missing
  key would mean `rawget` at every feature probe in the codebase. The read half
  is a nil handed to something that does not look at it; the write half is the
  leak.

  It raises rather than warning, which is the trade the maintainer log already records
  for this class: a guard that turns the bug into silence is worse than the
  bug, so prefer the loud failure.

  Scope is `module()` files. `modules/system`, `modules/tag` and
  `modules/entity` assign to a file-local `_M`, so a bare assignment there
  writes a worker-scoped *global* instead -- the same class through a different
  door, whose fix is a strict environment rather than this. `_NAME` is the
  field `module()` sets, and so is the exact test for "this file was jailed".
]]
do
  local function sealed(t, key, value)
    error(([[module %s: assignment to undeclared name '%s'.

Inside a file that calls module(), a bare assignment becomes a field on the
module table and outlives the request that made it. Declare it `local` -- above
the module() call if it is a load-time capture, inside the function if it is
working state.]]):format(tostring(rawget(t, '_NAME')), tostring(key)), 2)
  end

  local seal = {__newindex = sealed}

  function module_seal(name)
    local m = rawget(ophal.modules, name)

    -- A module that brought its own metatable keeps it: chaining one on would
    -- be guessing at what it is for. No shipped module does, and
    -- `module_tables_are_sealed` in the unit suite is what notices if that
    -- stops being true.
    if
      type(m) == 'table' and
      rawget(m, '_NAME') ~= nil and
      getmetatable(m) == nil
    then
      setmetatable(m, seal)
    end
  end

  function module_is_sealed(name)
    return getmetatable(rawget(ophal.modules, name) or {}) == seal
  end
end

function module_load(name)
  local status, err = pcall(require, 'modules.' .. name .. '.init')
  if not status then
    if type(log_error) == 'function' then
      log_error('module load failed', {
        event = 'module_load_failed',
        module = name,
        error = err,
      })
    end
    error('module: ' .. err)
  end

  module_seal(name)
end

function module_load_all()
  for _, name in pairs(module_list()) do
    module_load(name)
  end
end
