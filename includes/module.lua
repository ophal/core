function module_invoke_all(hook, ...)
  local result, r = {}

  for name, m in pairs(ophal.modules) do
    r = m[hook](...) -- function call
    if type(r) == [[table]] then
      for path, v in pairs(r) do
        v.module = name
        result[path] = v
      end
    else
      table.insert(result, r)
    end
  end

  return result
end