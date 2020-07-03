local _M = {}
ophal.modules.entity = _M

local t, module_invoke_all, route_arg = t, module_invoke_all, route_arg
local l, theme, empty = l, theme, seawolf.variable.empty
local xtable, config = seawolf.contrib.seawolf_table, settings.entity

local user_mod

--[[ Implements hook init().
]]
function _M.init()
  user_mod = ophal.modules.user
end

--[[ Implements hook route().
]]
function _M.route()
  local items = {}

  -- entity/create/%entity_type
  items['entity/create'] = {
    page_callback = {'default_page', 'create_page'},
    access_callback = {'entity_access', nil, 'create'},
  }

  -- entity/edit/%entity_type
  items['entity/edit'] = {
    page_callback = {'default_page', 'edit_page'},
    access_callback = {'entity_access', nil, 'update'},
  }

  -- entity/delete/%entity_type
  items['entity/delete'] = {
    page_callback = {'default_page', 'delete_page'},
    access_callback = {'entity_access', nil, 'delete'},
  }

  -- entity/save/%entity_type
  items['entity/save'] = {
    page_callback = {'default_page', 'save_service'},
    access_callback = {'entity_access', nil, 'create'},
    format = 'json',
  }

  -- entity/remove/%entity_type
  items['entity/remove'] = {
    page_callback = {'delete_service'},
    access_callback = {'entity_access', nil, 'delete'},
    format = 'json',
  }

  return items
end

do
  local infos = {}
  function _M.get_entity_type_info(entity_type)
    if empty(infos) then
      infos = module_invoke_all 'entity_type_info'
    end
    if entity_type then
      return infos[entity_type]
    end
    return infos
  end
end

--[[ Implements hook blocks_alter().
]]
function _M.blocks_alter(blocks)
  for entity_type, v in pairs(config) do
    xtable(v.parents):each(function(parent_type)
      if route_arg(0) == parent_type and not empty(route_arg(1)) then
        local info = _M.get_entity_type_info(entity_type)
        if info and _M.entity_access({type = entity_type}, 'create') then
          blocks['add_' .. entity_type] = {
            id = 'add_' .. entity_type,
            title = nil,
            body = ('<div class="new-entity"><p>%s</p></div>'):format(l(('Add new %s'):format(info.name[1]), ('entity/create/%s?parent_id=%s&parent_type=%s'):format(entity_type, route_arg(1), parent_type), {attributes = {class = 'button'}})),
            region = 'sidebar_last',
          }
        end
      end
    end)
  end
end

function _M.parse_route_args()
  local entity, parent
  local arg2, arg3 = route_arg(2), route_arg(3)
  local parent_id = _GET.parent_id

  entity = {
    id = tonumber(arg3),
    type = arg2,
  }

  if not empty(parent_id) then
    parent = {
      id = tonumber(parent_id),
      type = _GET.parent_type,
    }
  end

  return entity, parent
end

function _M.entity_access(entity, action)
  -- Lazy-load entity data
  if empty(entity) then
    entity = _M.parse_route_args()
  end

  local wrapper = {}
  setmetatable(wrapper, {__index = function(t, k)
    return entity[k] or (function()
      local entity_class = ophal.modules[rawget(t, 'type')]
      local data = entity_class.load(rawget(t, 'id'))
      return data and data[k] or nil
    end)()
  end})

  if
    empty(wrapper.type) or (
      ('update' == action or 'delete' == action) and
      empty(wrapper.id)
    )
  then
    return false
  end

  local account = user_mod.current()
  local info = _M.get_entity_type_info(wrapper.type)

  if user_mod.access('administer ' .. (info.name.plural or info.name[1])) then
    return true
  end

  if action == 'create' then
    return user_mod.access('create ' .. (info.name.plural or info.name[1]))
  elseif action == 'update' then
    return user_mod.access('edit own ' .. (info.name.plural or info.name[1])) and wrapper.user_id == account.id
  elseif action == 'read' then
    return user_mod.access('access ' .. (info.name.plural or info.name[1]))
  elseif action == 'delete' then
    return user_mod.access('delete own ' .. (info.name.plural or info.name[1])) and wrapper.user_id == account.id
  end

  return false
end

function _M.delete(entity)
  local rs, err

  rs, err = db_query('DELETE FROM ' .. entity.type .. ' WHERE id = ?', entity.id)

  for parent in pairs((config[entity.type] or {}).parents) do
    local query = ('DELETE FROM rel_%s_%s WHERE %s_id = ?'):format(entity.type, parent, entity.type)
    rs, err = db_query(query, entity.id)
  end

  if not err then
    module_invoke_all('entity_after_delete', entity)
  end

  return rs, err
end

--[[ Implements hook route_alter().

  Add default route_page to all entity that haven't one defined yet.
]]
function _M.route_alter(entity_type, items)
  local info = _M.get_entity_type_info(entity_type)
  local it = xtable(items)
  local entity_class = ophal.modules[entity_type]

  if entity_class and empty(items[entity_type]) then
    items[entity_type] = {
      page_callback = {
        module = entity_class.route_page and entity_type or 'entity',
        'route_page'
      },
      access_callback = {
        module =  entity_class.entity_access and entity_type or 'entity',
        'entity_access',
        {type = entity_type},
        'read'
      },
    }
  end
end

function _M.default_page(fn, ...)
  -- Call own entity's implementation whenever possible
  local entity_type = route_arg(2)
  local entity_class = ophal.modules[entity_type]
  if entity_class and entity_class[fn] then
    return entity_class[fn](...)
  end

  header('status', 404)
  page_set_title 'Entity not found'
  return ''
end

function _M.route_page()
  local entity_type = route_arg(0)
  local id = route_arg(1)

  if not empty(entity_type) then
    local info = _M.get_entity_type_info(entity_type)
    if info then
      if not empty(id) then
        return ophal.modules[info.module].entity_page()
      else
        page_set_title(t('Archive of %s'):format(info.name.plural or info.name[1]))
        return ophal.modules[info.module].archive_page()
      end
    end
  end
end

function _M.delete_page()
  local entity = _M.parse_route_args()
  local confirm = route_arg(4) == 'confirm'
  local title

  if not empty(entity) then
    local info = _M.get_entity_type_info(entity.type)
    if info then
      entity = ophal.modules[info.module].load(entity.id)
      if confirm then
        ophal.modules[info.module].delete(entity)
        goto ''
      else
        title = t('Delete %s: %s'):format(
          entity.type,
          entity.title or entity.id
        )
        page_set_title(title)
        return (xtable{
          '<h1>', title, '</h1>',
          '<div>', t('Are you sure?'), '</div>',
          l('Confirm', ('entity/delete/%s/%s/confirm'):format(entity.type, entity.id), {attributes = {class = 'button'}}),
          ' ',
          l('Cancel', ('%s/%s'):format(entity.type, entity.id)),
        }):concat()
      end
    end
  end
end

function theme.entity_links(variables)
  local page, entity, links, info

  page = variables.page
  if page == nil then page = false end

  entity = variables.entity
  if entity == nil then entity = {} end

  info = _M.get_entity_type_info(entity.type)
 
  links = entity.links
  if links == nil then links = {} end

  if not page then
    links[1 + #links] = l('Read more', entity.type .. '/' .. entity.id)
  end

  if _M.entity_access(entity, 'update') then
    links[1 + #links] = l('edit', 'entity/edit/' .. entity.type .. '/' .. entity.id)
  end

  if _M.entity_access(entity, 'delete') then
    links[1 + #links] = l('delete', 'entity/delete/' .. entity.type .. '/' .. entity.id)
  end

  return theme{'item_list', list = links, class = 'entity-links'}
end
