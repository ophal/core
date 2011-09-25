
--[[
  Look for path handlers in path_tree.
]]
function menu_get_handler()
  local a, path, aliased
  local paths, handler = ophal.paths
  local path_tree = init_path()
  for i = 1,#path_tree do
    a = #path_tree - (i - 1) -- start from bottom
    path = path_tree[a] -- get path from stack
    handler = paths[path] -- lookup handler
    if handler then
      return handler
    end
  end
end

function menu_execute_active_handler()
  local handler, content, status

  -- Load paths
  if #ophal.paths == 0 then
    ophal.paths = module_invoke_all([[menu]])
  end

  -- Execute handler
  handler = menu_get_handler()
  if not handler then
    handler = {title = [[Page not found]]}
    content = [[The requested page could not be found.]]
    page_set_title(handler.title)
  else
    page_set_title(handler.title) -- allow later override
    status, content = pcall(ophal.modules[handler.module][handler.page_callback])
    if not status then
      content = ([[module '%s': %s]]):format(handler.module, content)
    end
  end

  -- Render page
  print(theme([[html]], {header_title = ophal.header_title, title = ophal.title, content = content}))
end
