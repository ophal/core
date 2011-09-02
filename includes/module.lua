function module_invoke_all(hook, ...)
  local result, r = {}

  for _, m in pairs(ophal.modules) do
    r = m.menu(...)
    if type(r) == [[table]] then
      for path, v in pairs(r) do
        result[path] = v
      end
    else
      table.insert(result, r)
    end
  end

  return result
end