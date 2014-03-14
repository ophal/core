local env, theme, _GET, tonumber, ceil = env, theme, _GET, tonumber, math.ceil
local tinsert, tconcat, pairs, debug = table.insert, table.concat, pairs, debug
local pager, l, page_set_title, arg = pager, l, page_set_title, arg
local tonumber, format_date = tonumber, format_date
local empty, add_js, _SESSION = seawolf.variable.empty, add_js, _SESSION
local header, json, type, time = header, require 'dkjson', type, os.time
local print_t, require, modules = print_t, require, ophal.modules
local module_invoke_all, request_get_body = module_invoke_all, request_get_body
local error = error

local set_global = set_global

module 'ophal.modules.content'

local user

--[[
  Implements hook_init().
]]
function init()
  db_query = env.db_query
  db_last_insert_id = env.db_last_insert_id
  user = modules.user
end

--[[
  Implements hook_menu().
]]
function menu()
  items = {}
  items.content = {
    page_callback = 'router',
  }
  items['content/save'] = {
    page_callback = 'save_service',
    format = 'json',
  }
  return items
end

function load(id)
  local rs, err, content

  id = tonumber(id or 0)

  rs, err = db_query('SELECT * FROM content WHERE id = ?', id)
  if err then
    error(err)
  end

  content = rs:fetch(true)

  if content then
    content.type = 'content'
    module_invoke_all('content_load', content)
  end

  return content
end

function content_access(content, action)
  local account = _SESSION.user

  if user.access 'administer content' then
    return true
  end

  if action == 'create' then
    return user.access 'create content'
  elseif action == 'update' then
    return user.access 'edit own content' and content.user_id == account.id
  elseif action == 'read' then
    return user.access 'access content'
  elseif action == 'delete' then
    return user.access 'delete own content' and content.user_id == account.id
  end
end

function save_service()
  local input, parsed, pos, err, output, account, action, id

  if not user.is_logged_in() then
    header('status', 401)
  else
    id = tonumber(arg(2) or '')
    action = empty(id) and 'create' or 'update'
    output = {}

    content = load(id)

    if not content_access(content, action) then
      header('status', 401)
    elseif action == 'update' and empty(content) then
      header('status', 404)
      output.error = 'No such content.'
    else
      output.success = false
      input = request_get_body()
      parsed, pos, err = json.decode(input, 1, nil)
      if err then
        output.error = err
      elseif 'table' == type(parsed) and not empty(parsed) then
        parsed.id = id
        parsed.type = 'content'

        if type(parsed.status) == 'boolean' then
          parsed.status = parsed.status and 1 or 0
        end
        if type(parsed.promote) == 'boolean' then
          parsed.promote = parsed.promote and 1 or 0
        end

        if action == 'create' then
          id, err = create(parsed)
        elseif action == 'update' then
          do _, err = update(parsed) end
        end

        if err then
          output.error = err
        else
          output.id = id
          output.success = true
        end
      end
    end
  end

  return output
end

function create(entity)
  local rs, err
  rs, err = db_query('INSERT INTO content(user_id, title, teaser, body, status, promote, created) VALUES(?, ?, ?, ?, ?, ?, ?)', _SESSION.user.id, entity.title, entity.teaser, entity.body, entity.status, entity.promote, time())
  entity.id = db_last_insert_id()
  if not err then
    module_invoke_all('entity_after_save', entity)
  end
  return entity.id, err
end

function update(entity)
  local rs, err
  rs, err = db_query('UPDATE content SET title = ?, teaser = ?, body = ?, status = ?, promote = ?, changed = ? WHERE id = ?', entity.title, entity.teaser, entity.body, entity.status, entity.promote, time(), entity.id)
  if not err then
    module_invoke_all('entity_after_save', entity)
  end
  return rs, err
end

function router()
  local rs, err, ipp, current_page, num_pages, count, content, id, arg1

  arg1 = arg(1)

  if not empty(arg1) then
    if arg1 == 'create' then
      if not content_access(content, 'create') then
        page_set_title 'Access denied'
        header('status', 401)
        return ''
      end

      add_js 'libraries/jquery.min.js'
      add_js 'libraries/json2.js'
      add_js 'modules/content/content.js'

      page_set_title 'Create content'
      return theme.content_form{}
    end

    content = load(arg1)

    if empty(content) then
      page_set_title 'Page not found'
      header('header', 404)
      return ''
    elseif not content_access(content, 'read') then
      page_set_title 'Access denied'
      header('status', 401)
      return ''
    end

    if arg(2) == 'edit' then
      if not content_access(content, 'update') then
        page_set_title 'Access denied'
        header('status', 401)
        return ''
      end

      add_js 'libraries/jquery.min.js'
      add_js 'libraries/json2.js'
      add_js 'modules/content/content.js'
      page_set_title('Edit "' .. content.title .. '"')

      return theme.content_form(content)
    else
      page_set_title(content.title)
      if content.status or user.access 'administer content' then
        page_set_title(content.title)
        set_global('language', content.language)
        return function ()
          print_t{'content_page',
            account = user.load{id = content.user_id} or user.load{id = 0},
            content = content,
            format_date = format_date
          }
        end
      else
        page_set_title 'Access denied'
        header('status', 401)
        return ''
      end
    end
  else
    return frontpage()
  end
end

function frontpage()
  local rows = {}
  local rs, err, count, current_page, ipp, num_pages, query

  -- Count rows
  query = ('SELECT count(*) FROM content WHERE promote = 1 %s'):format(user.is_logged_in() and '' or 'AND status = 1')
  rs, err = db_query(query)
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
  query = ('SELECT * FROM content WHERE promote = 1 %s ORDER BY created DESC LIMIT ?, ?'):format(user.is_logged_in() and '' or 'AND status = 1')
  rs, err = db_query(query, (current_page -1)*ipp, ipp)
  if err then
    error(err)
  else
    for row in rs:rows(true) do
      tinsert(rows, function () print_t{'content_teaser', content = row} end)
    end
  end

  return function ()
    print_t{'content_frontpage', rows = rows}
    print_t{'pager', pages = pager('content', num_pages, current_page)}
  end
end

function theme.content_links(content, page)
  if page == nil then page = false end

  local links = {}

  if not page then
    tinsert(links, l('Read more', 'content/' .. content.id))
  end

  if content_access(content, 'update') then
    tinsert(links, l('edit', 'content/' .. content.id .. '/edit'))
  end

  return theme.item_list{list = links, class = 'content-links'}
end

function theme.content_frontpage(variables)
  local rows = variables.rows

  local output = {}

  for _, row in pairs(rows) do
    row()
  end
end

function theme.content_form(content)
  return theme{'form', method = 'POST',
    attributes = {id = empty(content.id) and 'content_create_form' or 'content_edit_form'},
    entity = content,
    elements = {
      {'hidden', attributes = {id = 'entity_id'}, value = content.id},
      {'textfield', title = 'Title', attributes = {id = 'content_title', size = 60}, value = content.title, weight = 10},
      {'textarea', title = 'Teaser', attributes = {id = 'content_teaser', cols = 60, rows = 10}, value = content.teaser, weight = 20},
      {'textarea', title = 'Body', attributes = {id = 'content_body', cols = 60, rows = 15}, value = content.body, weight = 30},
      {'checkbox', title = 'Status', attributes = {id = 'content_status'}, value = content.status, weight = 40},
      {'checkbox', title = 'Promote to frontpage', attributes = {id = 'content_promote'}, value = content.promote, weight = 50},
      {'markup', title = 'Created on', value = content.created and format_date(content.created) or '', weight = 60},
      {'button', attributes = {id = 'save_submit'}, value = 'Save', weight = 70},
    },
  }
end
