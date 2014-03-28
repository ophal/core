if not ophal.aliases.source then ophal.aliases.source = {} end
if not ophal.aliases.alias then ophal.aliases.alias = {} end


local explode = seawolf.text.explode
local aliases = ophal.aliases
local route_set_title, pcall = route_set_title, pcall


function route_register_alias(route, alias)
  aliases.source[route] = alias
  aliases.alias[alias] = route
end

do
  local arguments

  function arg(index)
    local source, rp

    index = index + 1
    if arguments == nil then
      rp = request_path()
      source = aliases.alias[rp]
      if source then
        rp = source
      end
      arguments = explode('/', rp ~= '' and rp or settings.site.frontpage)
    end

    return arguments[index]
  end
end

local slash = settings.slash

do
  local route_tree, route
  function init_route()
    local alias

    if route_tree == nil and route == nil then
      route_tree, route = {}

      -- build route tree
      for i = 1,8 do
        a = arg(i - 1)
        if a == nil or a == '' then
          break
        else
          route = (route or '') .. (route and slash or '') .. (a or '')
          table.insert(route_tree, route)
        end
      end
      if not #route_tree then
        error 'Route system error!'
      end
    end
    return route_tree, route
  end
end

function url(route, options)
  if options == nil then options = {} end
  if route == nil then route = '' end

  if not (options.alias or options.external) then
    alias = aliases.source[route]
    if alias then
      route = alias
    end
  end

  if options.external then
    return route
  end

  return (options.absolute and base.system_root or '') .. base.route .. route
end

function l(text, route, options)
  if options == nil then options = {} end

  local attributes = options.attributes or {}
  options.attributes = nil

  return theme{'a', 
    text = text,
    route = url(route, options),
    attributes = attributes,
  }
end

--[[
  Look for route handlers in route_tree.
]]
function route_get_handler()
  local a, route, aliased
  local routes, handler = ophal.routes
  local route_tree = init_route()

  for i = 1, #route_tree do
    a = #route_tree - (i - 1) -- start from bottom
    route = route_tree[a] -- get route from stack
    handler = routes[route] -- lookup handler
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

function route_execute_active_handler()
  local handler, content, status

  -- Execute handler
  handler = route_get_handler()
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
