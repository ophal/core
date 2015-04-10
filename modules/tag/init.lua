local _M = {
  entity_type = 'tag',
}
ophal.modules.tag = _M

local modules, config = ophal.modules, settings.tag
local theme, env, add_css, slash, l = theme, env, add_css, settings.slash, l
local tinsert, tconcat, pairs, ophal = table.insert, table.concat, pairs, ophal
local add_js, route_arg, trim, header = add_js, route_arg, seawolf.text.trim, header
local page_set_title, json, time = page_set_title, require 'dkjson', os.time
local type, empty, error, goto = type, seawolf.variable.empty, error, goto
local _SESSION, tonumber, _GET, ceil = _SESSION, tonumber, _GET, math.ceil
local pager, print_t, request_get_body = pager, print_t, request_get_body

local db_query, db_limit, db_last_insert_id, user_mod


function _M.get_tags()
  local rs, err, tags, order

  rs, err = db_query 'SELECT * FROM tag ORDER BY name'
  if err then
    error(err)
  else
    tags, order = {}, {}
    for tag in rs:rows(true) do
      tags[tag.id] = tag.name
      order[#order + 1] = tag.id
    end
  end

  return tags, order
end

--[[ Implements hook init().
]]
function _M.init()
  db_query = env.db_query
  db_limit = env.db_limit
  db_last_insert_id = env.db_last_insert_id
  user_mod = modules.user
end

--[[ Implements hook route().
]]
function _M.route()
  local items = {}

  items['admin/content/tags'] = {
    page_callback = 'manage_page',
    title = 'Tags manager',
    access_callback = {module = 'user', 'access', 'administer tags'},
  }
  items.tag = {
    page_callback = 'page',
    title = 'Tag page',
    access_callback = {module = 'user', 'access', 'access tags'},
  }
  items['tag/add'] = {
    page_callback = 'add_page',
    title = 'Add new tag',
    access_callback = {module = 'user', 'access', 'create tags'},
  }
  items['tag/edit'] = {
    page_callback = 'edit_page',
    title = 'Edit tag',
    access_callback = {module = 'user', 'access', 'edit own tags'},
  }
  items['tag/service'] = {
    page_callback = 'save_service',
    title = 'Tag web service',
    access_callback = {module = 'user', 'access', 'create tags'},
    format = 'json',
  }
  items['tag/delete'] = {
    page_callback = 'delete_page',
    title = 'Delete tag',
    access_callback = {module = 'user', 'access', 'delete own tags'},
  }

  return items
end

function _M.entity_access(entity, action)
  local account = user_mod.current()

  if user_mod.access 'administer tags' then
    return true
  end

  if action == 'create' then
    return user_mod.access 'create tags'
  elseif action == 'update' then
    return user_mod.access 'edit own tags' and entity.user_id == account.id
  elseif action == 'read' then
    return user_mod.access 'access tags'
  elseif action == 'delete' then
    return user_mod.access 'delete own tags' and entity.user_id == account.id
  end
end

--[[ Implements hook entity_load().
]]
function _M.entity_load(entity)
  local rs, err, tags

  if not config.entities[entity.type] then return end

  rs, err = db_query('SELECT t.* FROM field_tag ft JOIN tag t ON t.id = ft.tag_id WHERE ft.entity_type = ? AND ft.entity_id = ?', entity.type, entity.id)
  if err then
    error(err)
  else
    tags = {}
    -- Load current tags
    for row in rs:rows(true) do
      tags[row.id] = row.name
    end
  end

  entity.tags = tags
end

--[[ Implements hook entity_post_save().
]]
function _M.entity_after_save(entity)
  local rs, err, tags, in_tags

  if not config.entities[entity.type] then return end

  rs, err = db_query('SELECT tag_id id FROM field_tag WHERE entity_type = ? AND entity_id = ?', entity.type, entity.id)
  if err then
    error(err)
  else
    tags, in_tags = {}, {}

    -- Load current tags
    for row in rs:rows(true) do
      tags[row.id] = true
    end

    -- Add new tags
    for k, v in pairs(entity.tags or {}) do
      v = tonumber(v)
      in_tags[v] = true
      if not tags[v] then
        rs, err = db_query('INSERT INTO field_tag(entity_type, entity_id, tag_id) VALUES(?, ?, ?)', entity.type, entity.id, v)
        if err then
          error(err)
        end
      end
    end

    -- Remove unmarked tags
    for k in pairs(tags) do
      if in_tags[k] == nil then
        rs, err = db_query('DELETE FROM field_tag WHERE entity_type = ? AND entity_id = ? AND tag_id = ?', entity.type, entity.id, k)
        if err then
          error(err)
        end
      end
    end
  end
end

--[[ Implements hook entity_after_delete().
]]
function _M.entity_after_delete(entity)
  local rs, err

  if not config.entities[entity.type] then return end

  rs, err = db_query('DELETE FROM field_tag WHERE entity_type = ? AND entity_id = ?', entity.type, entity.id)
  if err then
    error(err)
  end
end

--[[ Implements hook menus_alter().
]]
function _M.menus_alter(menus)
  if user_mod.is_logged_in() then
    menus.primary_links.tags = 'Tags'
  end

  menus.tags_menu = function()
    local rs, err = db_query [[SELECT t.id, t.name
FROM tag t JOIN field_tag ft ON t.id = ft.tag_id
GROUP BY t.id
ORDER BY t.name]]
    local c, items = 0, {}
    for row in rs:rows(true) do
      c = c + 1
      items['tag/' .. row.id] = {weight = c*10, ('%s'):format(row.name)}
    end
    return items
  end

  menus.entity_tags_menu = function()
    local rs, err = db_query([[SELECT t.id, t.name
FROM tag t JOIN field_tag ft ON t.id = ft.tag_id
WHERE ft.entity_type = ? AND ft.entity_id = ?
GROUP BY t.id
ORDER BY t.name]], route_arg(0), tonumber(route_arg(1)))
    local c, items = 0, {}
    for row in rs:rows(true) do
      c = c + 1
      items['tag/' .. row.id] = {weight = c*10, ('%s'):format(row.name)}
    end
    return items
  end
end

function _M.load(entity_id)
  local rs, err = db_query('SELECT * FROM ' .. _M.entity_type .. ' WHERE id = ?', entity_id)

  if err then
    return nil, err
  end

  local entity, err = rs:fetch(true)

  if err then
    return nil, err
  elseif not empty(entity) then
    entity.type = _M.entity_type
    return entity
  end
end

function _M.create(entity)
  if entity.type == nil then entity.type = _M.entity_type end

  local rs, err = (function(id, ...)
    if id then
      return db_query([[
INSERT INTO tag(id, user_id, name, description, created, status)
VALUES(?, ?, ?, ?, ?, ?)]], id, ...)
    else
      local rs1, rs2 = db_query([[
INSERT INTO tag(user_id, name, description, created, status)
VALUES(?, ?, ?, ?, ?)]], ...)
      entity.id = db_last_insert_id('tag', 'id')
      return rs1, rs2
    end
  end)(
    entity.id,
    entity.user_id or user_mod.current().id,
    entity.name,
    entity.description,
    entity.created or time(),
    entity.status
  )

  if not err then
    module_invoke_all('entity_after_save', entity)
  end

  return entity.id, err
end

function _M.update(entity)
  if entity.type == nil then entity.type = _M.entity_type end

  local rs, err = db_query('UPDATE tag SET name = ?, description = ?, changed = ?, status = ? WHERE id = ?',
    entity.name,
    entity.description,
    time(),
    entity.status,
    entity.id
  )

  if not err then
    module_invoke_all('entity_after_save', entity)
  end

  return rs, err
end

function _M.delete(entity)
  local rs, err = db_query('DELETE FROM field_tag WHERE tag_id = ?', entity.id)

  if err then
    return nil, err
  end

  rs, err = db_query('DELETE FROM tag WHERE id = ?', entity.id)

  if err then
    return nil, err
  end

  return true
end

--[[ Implements endpoint callback: save.
]]
function _M.save_service()
  local input, parsed, pos, err, entity_id, output, target_fp

  local input, data, pos, err, account, action
  local output = {success = false}
  local entity = {id = tonumber(route_arg(2)), type = 'tag'}

  if entity.type ~= _M.entity_type then
    header('status', 401)
    output.error = 'Entity type invalid for this handler.'
  else
    action = empty(entity.id) and 'create' or 'update'
    do
      local _ = _M.load(entity.id)
      if not empty(_) then
        entity = _
      end
    end

    if not _M.entity_access(entity, action) then
      header('status', 401)
    elseif entity == 'update' and empty(entity) then
      header('status', 404)
      output.error = 'No such entity.'
    else
      input = request_get_body()
      data, pos, err = json.decode(input, 1, nil)
      data.id = entity.id

      if err then
        output.error = err
      elseif 'table' == type(data) and not empty(data) then
        data.type = _M.entity_type

        if type(data.status) == 'boolean' then
          data.status = data.status and 1 or 0
        end

        if not empty(data.name) then
          if data.action == 'create' then
            rs, err = _M.create(data)
            if err then
              output.error = err
            else
              output.success = true
            end
          elseif data.action == 'update' then
            rs, err = _M.update(data)
            if err then
              output.error = err
            else
              output.tag_id = data.id
              output.success = true
            end
          end
        end
        if data.action == 'delete' then
          rs, err = _M.delete(data)
          if err then
            output.error = err
          else
            output.success = true
          end
        end
      end
    end
  end

  return output
end
  
function _M.page()
  local rs, err, tag, current_page, ipp, num_pages, entity, attr, pagination, sql
  local count, tables, count_query, query, tags, output = 0, {}, {}, {}, {}, {}

  tag, err = _M.load(route_arg(1))

  if err then
    error(err)
  elseif empty(tag) then
    header('status', 404)
    return page_not_found()
  else
    -- Get tables to join with
    rs, err = db_query('SELECT entity_type FROM field_tag WHERE tag_id = ? GROUP BY entity_type', tag.id)
    if err then
      error(err)
    else
      for v in rs:rows(true) do
        tinsert(tables, v.entity_type)
        tinsert(count_query, 'SELECT COUNT(*) FROM ' .. v.entity_type .. " e JOIN field_tag ft ON '" .. v.entity_type .. "' = ft.entity_type AND e.id = ft.entity_id WHERE e.status = 1 AND ft.tag_id = ?")
        tinsert(query, 'SELECT e.*, ' .. "'" .. v.entity_type .. "'" .. ' "type" FROM ' .. v.entity_type .. " e JOIN field_tag ft ON '" .. v.entity_type .. "' = ft.entity_type AND e.id = ft.entity_id WHERE e.status = 1 AND ft.tag_id = ?")
      end
    end

    -- Count rows
    if not empty(count_query) then
      sql = tconcat(count_query, ' UNION ')
      rs, err = db_query(sql, tag.id)
      if err then
        error(err)
      else
        count = (rs:fetch() or {})[1]
      end
    end

    -- Calculate current page
    current_page = tonumber(_GET.page) or 1
    ipp = 10
    num_pages = ceil(count/ipp)

    if count > 0 then
      -- Render list
      sql = tconcat(query, ' UNION ') .. ' ORDER BY created DESC' .. db_limit()
      rs, err = db_query(sql, tag.id, (current_page -1)*ipp, ipp)
      if err then
        error(err)
      else
        for entity in rs:rows(true) do
          tinsert(output, entity)
        end
      end
    end

    tag.links = {}
    if user_mod.access 'edit own tags' then
      tag.links[1 + #tag.links] = l('edit', ('tag/edit/%s'):format(tag.id))
    end
    if user_mod.access 'delete own tags' then
      tag.links[1 + #tag.links] = l('delete', ('tag/delete/%s'):format(tag.id))
    end

    page_set_title(("%s (page %s)"):format(tag.name, _GET.page or 1))

    return function()
      print_t{'tag_page', tag = tag, rows = output}
      print_t{'pager', pages = pager(('tag/%s'):format(tag.id), num_pages, current_page)}
    end
  end
end

function _M.manage_page()
  local tags, rs, err, operations

  if not user_mod.is_logged_in() then
    goto 'user/login'
  end

  rs, err = db_query 'SELECT * FROM tag ORDER BY name'
  if err then
    error(err)
  else
    tags = {}
    for tag in rs:rows(true) do
      tag.operations = tconcat({
        l('view', 'tag/' .. tag.id),
        l('edit', 'tag/edit/' .. tag.id),
        l('delete', 'tag/delete/' .. tag.id),
      }, ' ')
      tinsert(tags, tag)
    end
  end

  operations = l('add new tag', 'tag/add')

  return theme{'tags_manage_page', tags = tags, operations = operations}
end

function _M.edit_page()
  local entity, err

  if not user_mod.is_logged_in() then
    goto 'user/login'
  end

  add_js 'modules/tag/tag_form.js'

  entity, err = _M.load(trim(route_arg(2)))
  if err then
    error(err)
  end

  page_set_title(("Edit tag '%s'"):format(entity.name))

  return theme{'tag_form', entity = entity}
end

function _M.add_page()
  local tag, rs, err

  if not user_mod.is_logged_in() then
    goto 'user/login'
  end

  add_js 'modules/tag/tag_form.js'

  page_set_title('Add new tag')

  return theme{'tag_form', entity = {type = _M.entity_type}}
end

function _M.delete_page()
  local entity, err

  if not user_mod.is_logged_in() then
    goto 'user/login'
  end

  entity, err = _M.load(trim(route_arg(2)))
  if err then
    error(err)
  elseif empty(entity) then
      header('status', 404)
    return 'Page not found'
  end

  return theme{'tag_delete_form', entity = entity}
end

--[[ Implements hook form_alter().
]]
function _M.form_alter(form)
  local entities = config.entities or {}

  for entity_type in pairs(entities) do
    if
      form.attributes.id == entity_type .. '_create_form' or
      form.attributes.id == entity_type .. '_edit_form'
    then
      add_js 'modules/tag/tag_form.js'
      tinsert(form.elements, {'tag_field', title = 'Tags', tags = form.entity.tags, attributes = {id = 'field_tags', size = 10}})
      break
    end
  end

end

function theme.tags_manage_page(variables)
  if variables.tags == nil then variables.tags = {} end

  local output, zebra, tags = {}, 'odd', variables.tags

  tinsert(output, variables.operations)
  tinsert(output, '<table id="tags-list" class="admin-table">')
  tinsert(output, '<thead><th>name</th><th>operations</th></thead>')
  for _, tag in pairs(tags) do
    if zebra == 'odd' then zebra = 'even' else zebra = 'odd' end
    tinsert(output, ('<tr class="%s">'):format(zebra))
    tinsert(output, ('<td>%s</td><td>%s</td>'):format(
      tag.name,
      tag.operations
    ))
    tinsert(output, '</tr>')
  end
  tinsert(output, '</table>')

  return tconcat(output)
end

function theme.tag_links(variables)
  local page, entity, links

  page = variables.page
  if page == nil then page = false end

  entity = variables.entity
  if entity == nil then entity = {} end

  links = entity.links
  if links == nil then links = {} end

  return theme{'item_list', list = links, class = 'tag-links'}
end

function theme.tag_form(variables)
  local entity = variables.entity

  if entity == nil then entity = {} end

  add_js(('modules/%s/%s_form.js'):format(entity.type, entity.type))

  local elements = {
    {'hidden', attributes = {id = 'entity_id'}, value = entity.id},
    {'hidden', attributes = {id = 'action'}, value = empty(entity.id) and 'create' or 'update'},
    {'textfield', title = 'Name', attributes = {id = 'name_field'}, value = entity.name, weight = 20},
    {'textarea', title = 'Description', attributes = {id = 'description_field', cols = 60, rows = 15}, value = entity.description, weight = 30},
    {'checkbox', title = 'Status', attributes = {id = 'status_field'}, value = entity.status, weight = 40},
    {'markup', title = 'Created on', value = entity.created and format_date(entity.created) or '', weight = 50},
    {'button', attributes = {id = 'save_submit'}, value = 'Save', weight = 90},
  }

  return theme{'form', method = 'POST',
    attributes = {id = empty(entity.id) and  entity.type .. '_create_form' or entity.type .. '_edit_form'},
    entity = entity,
    elements = elements,
  }
end

function theme.tag_delete_form(variables)
  local entity = variables.entity

  add_js(('modules/%s/%s_form.js'):format(entity.type, entity.type))

  return theme{'form',
    attributes = {id = 'tag_delete_form'},
    elements = {
      {'hidden', attributes = {id = 'entity_id'}, value = entity.id},
      {'markup', value = ("Are you sure you want to <strong>delete</strong> '%s'?"):format(entity.name)},
      {'button', attributes = {id = 'confirm_submit'}, value = 'Confirm'},
    },
  }
end

function theme.tag_page(variables)
  local tag = variables.tag
  local rows = variables.rows
  local items = {}

  print '<div>'
  print(tag.description or '')
  print_t{'tag_links', entity = tag}
  print '</div>'

  for _, v in pairs(rows) do
    module_invoke_all('entity_render', v, false)
    tinsert(items, theme{v.type .. '_teaser', entity = v})
  end

  if #rows < 1 then
    return 'There is no content under this tag already.'
  end
end

function theme.tag_field(variables)
  if variables == nil then variables = {} end

  local attributes = variables.attributes ~= nil and variables.attributes or {}

  attributes.multiple = 'multiple'
  attributes.required = 'required'

  local options, order = _M.get_tags()

  return theme{'select', attributes = attributes, options = options, order = order, choices = variables.tags or {}}
end

function theme.tags_menu()
  return theme{'menu', id = 'tags_menu'}
end

return _M
