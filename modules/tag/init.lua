local theme, env, add_css, slash, l = theme, env, add_css, settings.slash, l
local tinsert, tconcat, pairs, ophal = table.insert, table.concat, pairs, ophal
local add_js, arg, trim, header = add_js, arg, seawolf.text.trim, header
local page_set_title, json = page_set_title, require 'dkjson'
local type, empty, error, goto = type, seawolf.variable.empty, error, goto
local _SESSION, tonumber, _GET, ceil = _SESSION, tonumber, _GET, math.ceil
local pager, print_t, request_get_body = pager, print_t, request_get_body
local db_query, user_is_logged_in, db_last_insert_id

local debug = debug

module 'ophal.modules.tag'

function get_tags()
  local rs, err, tags

  rs, err = db_query 'SELECT * FROM tag'
  if err then
    error(err)
  else
    tags = {}
    for tag in rs:rows(true) do
      tags[tag.id] = tag.name
    end
  end

  return tags
end

--[[
  Implements hook boot().
]]
function boot()
  if ophal.modules.user then
    user_is_logged_in = ophal.modules.user.is_logged_in
  end
end

--[[
  Implements hook init().
]]
function init()
  db_query = env.db_query
  db_last_insert_id = env.db_last_insert_id
end

function menu()
  local items = {}

  items.tags = {
    page_callback = 'manage_page',
    title = 'Tags manager',
  }
  items.tag = {
    page_callback = 'page',
    title = 'Tag page',
  }
  items['tag/add'] = {
    page_callback = 'add_page',
    title = 'Add new tag',
  }
  items['tag/edit'] = {
    page_callback = 'edit_page',
    title = 'Edit tag',
  }
  items['tag/service'] = {
    page_callback = 'handle_service',
    title = 'Tag web service',
  }
  items['tag/delete'] = {
    page_callback = 'delete_page',
    title = 'Delete tag',
  }

  return items
end

--[[
  Implements hook content_load().
]]
function content_load(entity)
  local rs, err, tags

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

--[[
  Implements hook entity_post_save().
]]
function entity_after_save(entity)
  local rs, err, tags, in_tags

  rs, err = db_query('SELECT tag_id id FROM field_tag WHERE entity_id = ?', entity.id)
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

--[[
  Implements hook content_post_delete().
]]
function entity_post_delete(entity_id)
  rs, err = db_query('DELETE FROM field_tag WHERE entity_id = ?', entity_id)
  if err then
    error(err)
  end
end

--[[
  Implements hook menus_alter().
]]
function menus_alter(menus)
  local rs, err
  local account = _SESSION.user

  if account and not empty(account.id) then
    menus.primary_links.tags = 'Tags'
  end

  menus.tags_menu = {}
  rs, err = db_query [[SELECT t.id, t.name
FROM tag t JOIN field_tag ft ON t.id = ft.tag_id
GROUP BY t.id
ORDER BY t.name]]
  for row in rs:rows(true) do
    menus.tags_menu['tag/' .. row.id] = ('%s'):format(row.name)
  end
end

function handle_service()
  local input, parsed, pos, err, entity_id, output, target_fp

  if not user_is_logged_in() then
    header('status', 404)
  else
    header('content-type', 'application/json; charset=utf-8')

    output = {success = false}
    input = request_get_body()
    parsed, pos, err = json.decode(input, 1, nil)

    if err then
      error(err)
    elseif
      'table' == type(parsed) and not empty(parsed.action)
    then
      if not empty(parsed.name) then
        if parsed.action == 'create' then
          rs, err = db_query('INSERT INTO tag(name) VALUES(?)', parsed.name)
          if err then
            error(err)
          else
            output.tag_id = db_last_insert_id()
            if output.tag_id then
              output.success = true
            end
          end
        elseif parsed.action == 'update' then
          rs, err = db_query('SELECT * FROM tag WHERE id = ?', parsed.id)
          if err then
            error(err)
          else
            tag = rs:fetch(true)
            rs, err = db_query('UPDATE tag SET name = ? WHERE id = ?', parsed.name, tag.id)
            if err then
              error(err)
            else
              output.tag_id = parsed.id
              output.success = true
            end
          end
        end
      end
      if parsed.action == 'delete' then
        rs, err = db_query('SELECT * FROM tag WHERE id = ?', parsed.id)
        if err then
          error(err)
        else
          tag = rs:fetch(true)
          rs, err = db_query('DELETE FROM field_tag WHERE tag_id = ?', tag.id)
          if err then
            error(err)
          end
          rs, err = db_query('DELETE FROM tag WHERE id = ?', tag.id)
          if err then
            error(err)
          else
            output.success = true
          end
        end
      end
    end

    output = json.encode(output)
  end

  theme.html = function () return output or '' end
end
  
function page()
  local rs, err, tag, current_page, ipp, num_pages, entity, attr, pagination, count
  local tables, count_query, query, tags, output = {}, {}, {}, {}, {}

  if _SESSION and not empty(_SESSION.user.id) then
    add_css(('modules%spanel%spanel.css'):format(slash, slash))
  end

  rs, err = db_query('SELECT * FROM tag WHERE id = ?', arg(1))
  if err then
    error(err)
  else
    tag = rs:fetch(true)

    if tag then
      -- Get tables to join with
      rs, err = db_query('SELECT entity_type FROM field_tag WHERE tag_id = ? GROUP BY entity_type', tag.id)
      if err then
        error(err)
      else
        for v in rs:rows(true) do
          tinsert(tables, v.entity_type)
          tinsert(count_query, 'SELECT COUNT(*) FROM ' .. v.entity_type .. ' e JOIN field_tag ft ON e.id = ft.entity_id WHERE e.status = 1 AND ft.tag_id = ?')
          tinsert(query, 'SELECT e.*, "' .. v.entity_type .. '" type FROM ' .. v.entity_type .. ' e JOIN field_tag ft ON e.id = ft.entity_id WHERE e.status = 1 AND ft.tag_id = ?')
        end
      end

      -- Count rows
      rs, err = db_query(tconcat(count_query, ' UNION '), tag.id)
      if err then
        error(err)
      else
        count = (rs:fetch() or {})[1]
      end

      -- Calculate current page
      current_page = tonumber(_GET.page) or 1
      ipp = 10
      num_pages = ceil(count/ipp)

      -- Render list
      rs, err = db_query(tconcat(query, ' UNION ').. ' ORDER BY created DESC LIMIT ?, ?', tag.id, (current_page -1)*ipp, ipp)
      if err then
        error(err)
      else
        for entity in rs:rows(true) do
          rs, err = db_query('SELECT * FROM ' .. entity.type .. ' WHERE id = ?', entity.id)
          tinsert(output, entity)
        end
      end
    end

    if tag and _SESSION then
      tag.links = tconcat{
        l('edit', ('tag/edit/%s'):format(tag.id)),
        l('delete', ('tag/delete/%s'):format(tag.id)),
      }
    end
  end

  page_set_title(("%s (page %s)"):format(tag.name, _GET.page or 1))

  return function()
    print_t{'tag_page', tag = tag, rows = output}
    print_t{'pager', pages = pager(('tag/%s'):format(tag.id), num_pages, current_page)}
  end
end

function manage_page()
  local tags, rs, err, operations

  if not user_is_logged_in() then
    goto 'user/login'
  end

  rs, err = db_query 'SELECT * FROM tag'
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

function edit_page()
  local tag, rs, err

  if not user_is_logged_in() then
    goto 'user/login'
  end

  add_js 'libraries/jquery.min.js'
  add_js 'modules/tag/tag.js'

  rs, err = db_query('SELECT * FROM tag WHERE id = ?', trim(arg(2)))
  if err then
    error(err)
  else
    tag = rs:fetch(true)
  end

  page_set_title(("Edit tag '%s'"):format(tag.name))

  return theme{'tag_save_form', tag = tag}
end

function add_page()
  local tag, rs, err

  if not user_is_logged_in() then
    goto 'user/login'
  end

  add_js 'libraries/jquery.min.js'
  add_js 'modules/tag/tag.js'

  page_set_title('Add new tag')

  return theme{'tag_save_form', tag = {}}
end

function delete_page()
  local tag, rs, err

  if not user_is_logged_in() then
    goto 'user/login'
  end

  add_js 'libraries/jquery.min.js'
  add_js 'modules/tag/tag.js'

  rs, err = db_query('SELECT * FROM tag WHERE id = ?', trim(arg(2)))
  if err then
    error(err)
  else
    tag = rs:fetch(true)
  end

  return theme{'tag_delete_form', tag = tag}
end

--[[
  Implements hook form_alter().
]]
function form_alter(form)
  if
    form.attributes.id == 'content_create_form' or
    form.attributes.id == 'content_edit_form'
  then
    add_js 'modules/tag/tag.js'
    tinsert(form.elements, {'tag_field', title = 'Tags', tags = form.entity.tags, attributes = {id = 'field_tags'}})
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

function theme.tag_save_form(variables)
  local tag = variables.tag
  local row = '<tr><td class="field-name" valign="top">%s:</td><td>%s</td></tr>'

  return tconcat{
    '<div id="tag_save_form"><table class="form">',
    theme.hidden{attributes = {id = 'tag_id'}, value = tag.id},
    theme.hidden{attributes = {id = 'action'}, value = empty(tag.id) and 'create' or 'update'},
    row:format('Name', theme.textfield{attributes = {id = 'tag_name'}, value = tag.name}),
    ('<tr><td colspan="2" align="right">%s</td></tr>'):format(theme.button{attributes = {id = 'save_submit'}, value = 'Save'}),
    '</table></div>',
  }
end

function theme.tag_delete_form(variables)
  local tag = variables.tag

  return tconcat{
    '<div id="tag_delete_form"><table class="form">',
    theme.hidden{attributes = {id = 'tag_id'}, value = tag.id},
    ("Are you sure you want to <strong>delete</strong> '%s'?"):format(tag.name),
    '<br />',
    theme.button{attributes = {id = 'confirm_submit'}, value = 'Confirm'},
    '</table></div>',
  }
end

function theme.tag_page(variables)
  local tag = variables.tag
  local rows = variables.rows
  local items = {}

  for _, v in pairs(rows) do
    tinsert(items, theme{v.type .. '_teaser', [v.type] = v})
  end

  return function ()
    tconcat{
      '<div class="tag_page">',
      tag.links and ('<div class="admin-links" align="center">%s</div>'):format(tag.links) or '',
      theme{'item_list', list = items},
      '</div>',
    }
  end
end

function theme.tag_field(variables)
  if variables == nil then variables = {} end

  local attributes = variables.attributes ~= nil and variables.attributes or {}

  attributes.multiple = 'multiple'
  attributes.required = 'required'

  return theme{'select', attributes = attributes, options = get_tags(), choices = variables.tags or {}}
end

function theme.tags_menu()
  return theme{'menu', id = 'tags_menu'}
end
