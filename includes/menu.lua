function menu_execute_active_handler()
  local handler, content

  -- Load paths
  if not ophal.paths then
    ophal.paths = module_invoke_all([[menu]])
  end

  -- Execute handler
  handler = ophal.paths[_GET.q]
  if not handler then
    handler = {title = [[Page not found]]}
    content = [[The requested page could not be found.]]
  else
    content = ophal.modules[handler.module][handler.page_callback]()
  end

  -- Render page
  page_set_title(handler.title)
  theme([[html]], {title = ophal.title, content = content})
end