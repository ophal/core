if not ophal.aliases.source then ophal.aliases.source = {} end
if not ophal.aliases.alias then ophal.aliases.alias = {} end
if not ophal.redirects.source then ophal.redirects.source = {} end
if not ophal.redirects.target then ophal.redirects.target = {} end

local explode = seawolf.text.explode
local table_shift = seawolf.contrib.table_shift
local aliases = ophal.aliases
local redirects = ophal.redirects
local route_set_title, pcall = route_set_title, pcall
local empty = seawolf.variable.empty

function route_register_alias(source, alias)
  aliases.source[source] = alias
  aliases.alias[alias] = source
end

function route_aliases_load()
  local alias
  local rs, err = db_query 'SELECT * FROM route_alias'
  for row in rs:rows(true) do
    alias = row.alias
    if (row.language or 'all') ~= 'all' and settings.route_aliases_prepend_language then
      alias = row.language .. '/' .. row.alias
    end
    route_register_alias(row.source, alias)
  end
end

function route_read_alias(id)
  local rs = db_query('SELECT * FROM route_alias WHERE id = ?', id)
  return rs:fetch(true)
end

function route_create_alias(entity)
  if empty(entity.language) then
    entity.language = 'all'
  end

  local rs, err

  if entity.type == nil then entity.type = 'route_alias' end

  if entity.id then
    rs, err = db_query([[
INSERT INTO route_alias(id, source, alias, language)
VALUES(?, ?, ?, ?)]],
      entity.id,
      entity.source,
      entity.alias,
      entity.language
    )
  else
    rs, err = db_query([[
INSERT INTO route_alias(source, alias, language)
VALUES(?, ?, ?)]],
      entity.source,
      entity.alias,
      entity.language
    )
    entity.id = db_last_insert_id('route_alias', 'id')
  end

  if not err then
    module_invoke_all('entity_after_save', entity)
  end
  return entity.id, err
end

function route_update_alias(id, entity)
  local keys, placeholders = {}, {}
  local record = route_read_alias(id)
  for _, v in pairs{'source', 'alias', 'language'} do
    record[v] = entity[v]
  end
  return db_query('UPDATE route_alias SET source = ?, alias = ?, language = ? WHERE id = ?', record.source, record.alias, record.language, id)
end

function route_delete_alias(id)
  return db_query('DELETE FROM route_alias WHERE id = ?', id)
end

function route_redirect()
  local redirect = ophal.redirects.source[request_path()]
  if redirect then
    goto(redirect[1], redirect[2])
  end
end

function route_register_redirect(source, target, http_code)
  redirects.source[source] = {target, http_code}
  redirects.target[target] = source
end

function route_redirects_load()
  local target
  local rs, err = db_query 'SELECT * FROM route_redirect'
  for row in rs:rows(true) do
    target = row.target
    if (row.language or 'all') ~= 'all' and settings.route_redirects_prepend_language then
      target = row.language .. '/' .. target
    end
    route_register_redirect(row.source, target, row.type)
  end
end

function route_create_redirect(entity)
  if empty(entity.language) then
    entity.language = 'all'
  end

  local rs, err

  if entity.type == nil then entity.type = 'route_redirect' end

  if entity.id then
    rs, err = db_query([[
INSERT INTO route_redirect(id, source, alias, language, type)
VALUES(?, ?, ?, ?, ?)]],
      entity.id,
      entity.source,
      entity.target,
      entity.language,
      entity.type
    )
  else
    rs, err = db_query([[
INSERT INTO route_redirect(source, target, language, type)
VALUES(?, ?, ?, ?)]],
      entity.source,
      entity.target,
      entity.language,
      entity.type
    )
    entity.id = db_last_insert_id('route_redirect', 'id')
  end

  if not err then
    module_invoke_all('entity_after_save', entity)
  end
  return entity.id, err
end

function route_read_redirect(id)
  local rs = db_query('SELECT * FROM route_redirect WHERE id = ?', id)
  return rs:fetch(true)
end

function route_update_redirect(id, entity)
  local keys, placeholders = {}, {}
  local record = route_read_redirect(id)
  for _, v in pairs{'source', 'alias', 'language', 'type'} do
    record[v] = entity[v]
  end
  return db_query('UPDATE route_redirect SET source = ?, target = ?, language = ?, type = ? WHERE id = ?', record.source, record.target, record.language, record.type, id)
end

function route_delete_redirect(id)
  return db_query('DELETE FROM route_redirect WHERE id = ?', id)
end

do
  local arguments

  function route_arg(index)
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
        a = route_arg(i - 1)
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

function route_build_handler(handler, module_name)
  local callback
  local known_callbacks = {'access_callback', 'page_callback'}

  handler.module = module_name -- register module name

  for _, v in pairs(known_callbacks) do
    callback = handler[v]
    if type(callback) == 'string' then
      handler[v] = {
        callback,
        module = module_name,
      }
    elseif type(callback) == 'table' then
      handler[v] = {
        callback[1],
        module = callback.module or module_name,
        arguments = table_shift(callback),
      }
    end
  end
end

function route_build_routes()
  local err
  local routes, r = {}

  for name, m in pairs(ophal.modules) do
    if m.route then
      r, err = m.route() -- call hook implementation
      if err then
        return nil, err
      end
      if type(r) == 'table' then
        module_invoke_all('route_alter', name, r)

        for k, v in pairs(r) do
          route_build_handler(v, name)
          routes[k] = v
        end
      elseif r then
        table.insert(routes, r)
      end
    end
  end

  return routes
end

--[[ Generates an internal or external URL.

  Params:
    options (optional): A table with the following elements:
      'alias': Whether the given path is a URL alias already.
      'absolute': Whether to force the output to be an absolute link.
      'external': Whether the given path is an external URL.
]]
function url(route, options)
  if options == nil then options = {} end
  if route == nil then route = '' end

  local alias

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
      handler.route = route
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

  module_invoke_all('route_validate_handler', handler)

  return handler
end

function route_execute_callback(handler, callback)
  local func, result
  local status = true

  if handler[callback] then
    func = ophal.modules[handler[callback].module][handler[callback][1]]
    status, result = pcall(func, unpack(handler[callback].arguments or {}))
    if not status then
      result = ("module '%s': %s"):format(handler.module, result)
    end
  end

  return status, result
end

function route_execute_active_handler()
  local handler, status, content

  -- Execute handler
  handler = route_get_handler()
  if handler.error then
    header('status', handler.error)
    content = handler.content
    page_set_title(handler.title)
  else
    page_set_title(handler.title) -- allow later override
    status, content = route_execute_callback(handler, 'page_callback')
  end

  -- Render content
  print_t{handler.format,
    status = status,
    header_title = ophal.header_title,
    title = ophal.title,
    content = content,
    head = get_head(),
    javascript = get_js(),
    css = get_css(),
    regions = theme_get_regions(),
  }
end

function route_forbidden(variables)
  if nil == variables then variables = {} end

  -- Defaults
  variables.header_title = variables.header_title or 'Access denied'
  variables.title = variables.title or 'Access denied'
  variables.body = variables.body or 'You have not access to this page.'

  module_invoke_all('route_forbidden_alter', variables)

  header('status', 401)
  page_set_title(variables.header_title, variables.title)

  return variables.body
end

function route_not_found(variables)
  if nil == variables then variables = {} end

  -- Defaults
  variables.header_title = variables.header_title or 'Page not found'
  variables.title = variables.title or 'Page not found'
  variables.body = variables.body or body 'The requested page could not be found.'

  module_invoke_all('route_not_found_alter', variables)

  header('status', 404)
  page_set_title(variables.header_title, variables.title)

  return variables.body
end
