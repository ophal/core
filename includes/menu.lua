local get_css, get_js, init_path = get_css, get_js, init_path
local path_set_title, pcall, print_t = path_set_title, pcall, print_t

--[[
  Look for path handlers in path_tree.
]]
function menu_get_handler()
  local a, path, aliased
  local paths, handler = ophal.paths
  local path_tree = init_path()

  for i = 1, #path_tree do
    a = #path_tree - (i - 1) -- start from bottom
    path = path_tree[a] -- get path from stack
    handler = paths[path] -- lookup handler
    if handler then
      break
    end
  end

  if not handler then
    handler = {
      error = 404,
      title = 'Page not found',
      content = 'The requested page could not be found.',
      format = 'html',
    }
  end

  if handler.format == nil then
    handler.format = 'html' -- default output format
  end

  return handler
end

function menu_execute_active_handler()
  local handler, content, status

  -- Execute handler
  handler = menu_get_handler()
  if handler.error then
    header('status', handler.error)
    content = handler.content
    page_set_title(handler.title)
  else
    page_set_title(handler.title) -- allow later override
    status, content = pcall(ophal.modules[handler.module][handler.page_callback])
    if not status then
      content = ("module '%s': %s"):format(handler.module, content)
    end
  end

  -- Render content
  print_t{handler.format,
    header_title = ophal.header_title,
    title = ophal.title,
    content = content,
    javascript = get_js(),
    css = get_css(),
  }
end
