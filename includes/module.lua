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
