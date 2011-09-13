function menu_get_handler()
  local paths, a, handler = ophal.paths
  local path_tree = sanitize_path()
  for i = 1,#path_tree do
    a = #path_tree - (i - 1) -- start from end
    handler = paths[path_tree[a]]
    if handler ~= nil then
      return handler
    end
  end
end

function menu_execute_active_handler()
  local handler, content, status

  -- Load paths
  if not ophal.paths then
    ophal.paths = module_invoke_all([[menu]])
  end

  -- Execute handler
  handler = menu_get_handler()
  if not handler then
    handler = {title = [[Page not found]]}
    content = [[The requested page could not be found.]]
  else
    status, content = pcall(ophal.modules[handler.module][handler.page_callback])
    if not status then
      content = ([[module '%s': %s]]):format(handler.module, content)
    end
  end

  -- Render page
  page_set_title(handler.title)
  print(theme([[html]], {header_title = ophal.title, title = handler.title, content = content}))
end
