local _M = {
  entity_type = 'content',
}
ophal.modules[_M.entity_type] = _M

local config = settings.content
local env, theme, _GET, tonumber, ceil = env, theme, _GET, tonumber, math.ceil
local tinsert, tconcat, pairs, debug = table.insert, table.concat, pairs, debug
local pager, l, page_set_title, arg = pager, l, page_set_title, route_arg
local tonumber, format_date = tonumber, format_date
local empty, add_js, ophal, t = seawolf.variable.empty, add_js, ophal, t
local header, json, type, time = header, require 'dkjson', type, os.time
local print_t, require, modules = print_t, require, ophal.modules
local module_invoke_all, request_get_body = module_invoke_all, request_get_body
local csrf_validate_request, csrf_denied = csrf_validate_request, csrf_denied
local error = error
local projection = require 'includes.projection'
local projection_query = projection.query
local projection_exec = projection.exec
local projection_touch = projection.touch
local projection_version = projection.version
local projection_is_missing_table = projection.is_missing_table

local set_global = set_global

module 'ophal.modules.content'

local user_mod, db_query, db_limit, db_last_insert_id
local CONTENT_PUBLIC_KEY = 'content_public'

--[[ Implements hook init().
]]
function init()
  db_query = env.db_query
  db_limit = env.db_limit
  db_last_insert_id = env.db_last_insert_id
  user_mod = modules.user
end

--[[ Implements hook route().
]]
function route()
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

local function hydrate(entity)
  if entity then
    entity.type = 'content'
    module_invoke_all('entity_load', entity)
  end

  return entity
end

local function load_legacy(id)
  local rs, err, entity

  id = tonumber(id or 0)

  rs, err = db_query('SELECT * FROM content WHERE id = ?', id)
  if err then
    error(err)
  end

  return rs:fetch(true)
end

local function content_projection_write(entity)
  local ok, err
  local updated_at = time()

  ok, err = projection_exec('DELETE FROM content_public WHERE id = ?', entity.id)
  if not ok then
    if projection_is_missing_table(err, 'content_public') then
      return true
    end

    return nil, err
  end

  ok, err = projection_exec([[
INSERT INTO content_public(
  id, user_id, language, title, teaser, body,
  created, changed, status, promote, route, updated_at
) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)]],
    entity.id,
    entity.user_id,
    entity.language,
    entity.title,
    entity.teaser,
    entity.body,
    entity.created,
    entity.changed,
    entity.status,
    entity.promote,
    'content/' .. entity.id,
    updated_at
  )

  if not ok then
    if projection_is_missing_table(err, 'content_public') then
      return true
    end

    return nil, err
  end

  projection_touch(CONTENT_PUBLIC_KEY, updated_at)
  return true
end

local function content_projection_delete(id)
  local ok, err = projection_exec('DELETE FROM content_public WHERE id = ?', id)

  if not ok then
    if projection_is_missing_table(err, 'content_public') then
      return true
    end

    return nil, err
  end

  projection_touch(CONTENT_PUBLIC_KEY)
  return true
end

local function content_projection_rebuild_all()
  local rs, err = db_query('SELECT * FROM content')
  local row
  local ok

  ok, err = projection_exec('DELETE FROM content_public')
  if not ok then
    if projection_is_missing_table(err, 'content_public') then
      return false
    end

    error(err)
  end

  for row in rs:rows(true) do
    ok, err = content_projection_write(row)
    if not ok then
      error(err)
    end
  end

  projection_touch(CONTENT_PUBLIC_KEY)
  return true
end

local function content_projection_ready()
  local version, err = projection_version(CONTENT_PUBLIC_KEY)

  if version ~= nil then
    return true
  end

  if err and not projection_is_missing_table(err, 'projection_version') then
    error(err)
  end

  return content_projection_rebuild_all()
end

local function load_projection(id)
  local rs, err

  if not content_projection_ready() then
    return nil
  end

  rs, err = projection_query('SELECT * FROM content_public WHERE id = ?', id)
  if not rs then
    if projection_is_missing_table(err, 'content_public') then
      return nil
    end

    error(err)
  end

  return rs:fetch(true)
end

function load(id)
  local entity

  id = tonumber(id or 0)
  entity = load_projection(id)

  if not entity then
    entity = load_legacy(id)
    if entity then
      content_projection_write(entity)
    end
  end

  return hydrate(entity)
end

function _M.entity_access(entity, action)
  local account = user_mod.current()

  if user_mod.access 'administer content' then
    return true
  end

  if action == 'create' then
    return user_mod.access 'create content'
  elseif action == 'update' then
    return user_mod.access 'edit own content' and entity.user_id == account.id
  elseif action == 'read' then
    return user_mod.access 'access content'
  elseif action == 'delete' then
    return user_mod.access 'delete own content' and entity.user_id == account.id
  end
end

function _M.entity_type_info()
  return {
    [_M.entity_type] = {
      name = {'content', plural = 'content'},
      module = _M.entity_type,
    }
  }
end

function save_service()
  local input, parsed, pos, err, output, account, action, id
  local entity

  if not user_mod.is_logged_in() then
    header('status', 401)
  else
    id = tonumber(arg(2) or '')
    action = empty(id) and 'create' or 'update'
    output = {}

    entity = load(id)

    output.success = false
    input = request_get_body()
    parsed, pos, err = json.decode(input, 1, nil)
    if err then
      output.error = err
    elseif not csrf_validate_request(parsed) then
      csrf_denied(output)
    elseif not _M.entity_access(entity, action) then
      header('status', 401)
    elseif action == 'update' and empty(entity) then
      header('status', 404)
      output.error = 'No such content.'
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

  return output
end

function create(entity)
  local rs, err

  if entity.type == nil then entity.type = 'content' end

  if entity.id then
    rs, err = db_query([[
INSERT INTO content(id, user_id, title, teaser, body, status, promote, created)
VALUES(?, ?, ?, ?, ?, ?, ?, ?)]],
      entity.id,
      entity.user_id or user_mod.current().id,
      entity.title,
      entity.teaser,
      entity.body,
      entity.status,
      entity.promote or false,
      entity.created or time()
    )
  else
    rs, err = db_query([[
INSERT INTO content(user_id, title, teaser, body, status, promote, created)
VALUES(?, ?, ?, ?, ?, ?, ?)]],
      entity.user_id or user_mod.current().id,
      entity.title,
      entity.teaser,
      entity.body,
      entity.status,
      entity.promote or false,
      entity.created or time()
    )
    entity.id = db_last_insert_id('content', 'id')
  end

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

function delete(entity)
  local rs, err
  rs, err = db_query('DELETE FROM content WHERE id = ?', entity.id)
  if not err then
    module_invoke_all('entity_after_delete', entity)
  end
  return rs, err
end

function router()
  local rs, err, ipp, current_page, num_pages, count, entity, id, arg1
  local account = user_mod.current()

  arg1 = arg(1)

  if not empty(arg1) then
    if arg1 == 'create' then
      if not _M.entity_access(entity, 'create') then
        page_set_title 'Access denied'
        header('status', 401)
        return ''
      end

      add_js 'libraries/jquery.min.js'
      add_js 'libraries/json2.js'
      add_js 'modules/content/content.js'

      page_set_title 'Create content'
      return theme{'content_form'}
    end

    entity = load(arg1)

    if empty(entity) then
      page_set_title 'Page not found'
      header('status', 404)
      return ''
    elseif not _M.entity_access(entity, 'read') then
      page_set_title 'Access denied'
      header('status', 401)
      return ''
    end

    if arg(2) == 'edit' then
      if not _M.entity_access(entity, 'update') then
        page_set_title 'Access denied'
        header('status', 401)
        return ''
      end

      add_js 'libraries/jquery.min.js'
      add_js 'libraries/json2.js'
      add_js 'modules/content/content.js'
      page_set_title('Edit "' .. entity.title .. '"')

      return theme{'content_form', entity = entity}
    else
      page_set_title(entity.title)
      if not empty(entity.status) or entity.user_id == account.id or user_mod.access 'administer content' then
        page_set_title(entity.title)
        set_global('language', entity.language)
        module_invoke_all('entity_render', entity)
        return function ()
          print_t{'content_page',
            account = user_mod.load(entity.user_id) or user_mod.load(0),
            entity = entity,
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
  local use_projection = content_projection_ready()

  -- Calculate current page
  current_page = tonumber(_GET.page) or 1
  ipp = config.items_per_page or 10
  query = (user_mod.is_logged_in() and '' or 'AND status = 1')

  -- Count rows
  if use_projection then
    rs, err = projection_query(
      ('SELECT count(*) FROM content_public WHERE promote = 1 %s'):format(query)
    )
    if not rs then
      if projection_is_missing_table(err, 'content_public') then
        use_projection = false
      else
        error(err)
      end
    else
      count = (rs:fetch() or {})[1]
    end
  end

  if not use_projection then
    rs, err = db_query(('SELECT count(*) FROM content WHERE promote = 1 %s'):format(query))
    if err then
      error(err)
    else
      count = (rs:fetch() or {})[1]
    end
  end

  num_pages = ceil(count/ipp)

  -- Render list
  if use_projection then
    rs, err = projection_query(
      ('SELECT * FROM content_public WHERE promote = 1 %s ORDER BY created DESC' .. db_limit()):format(query),
      (current_page -1)*ipp,
      ipp
    )
    if not rs then
      if projection_is_missing_table(err, 'content_public') then
        use_projection = false
      else
        error(err)
      end
    end
  end

  if not use_projection then
    rs, err = db_query(
      ('SELECT * FROM content WHERE promote = 1 %s ORDER BY created DESC' .. db_limit()):format(query),
      (current_page -1)*ipp,
      ipp
    )
    if err then
      error(err)
    end
  end

  for row in rs:rows(true) do
    if not use_projection then
      content_projection_write(row)
    end
    tinsert(rows, function () print_t{'content_teaser', entity = row} end)
  end

  if num_pages > 1 then
    page_set_title(("%s (page %s)"):format(t('Frontpage'), _GET.page or 1))
  end

  return function ()
    print_t{'content_frontpage', rows = rows}
    print_t{'pager', pages = pager('content', num_pages, current_page)}
  end
end

function entity_after_save(entity)
  if entity and entity.type == 'content' and entity.id then
    local stored = load_legacy(entity.id)
    if stored then
      content_projection_write(stored)
    end
  end
end

function entity_after_delete(entity)
  if entity and entity.type == 'content' and entity.id then
    content_projection_delete(entity.id)
  end
end

function theme.content_links(variables)
  local page, entity, links

  page = variables.page
  if page == nil then page = false end

  entity = variables.entity
  if entity == nil then entity = {} end

  links = entity.links
  if links == nil then links = {} end

  if not page then
    links[1 + #links] = l('Read more', 'content/' .. entity.id)
  end

  if _M.entity_access(entity, 'update') then
    links[1 + #links] = l('edit', 'content/' .. entity.id .. '/edit')
  end

  return theme{'item_list', list = links, class = 'content-links'}
end

function theme.content_frontpage(variables)
  local rows = variables.rows

  local output = {}

  for _, row in pairs(rows) do
    row()
  end
end

function theme.content_form(variables)
  local entity = variables.entity

  if entity == nil then entity = {} end

  return theme{'form', method = 'POST',
    attributes = {id = empty(entity.id) and 'content_create_form' or 'content_edit_form'},
    entity = entity,
    elements = {
      {'hidden', attributes = {id = 'entity_id'}, value = entity.id},
      {'textfield', title = 'Title', attributes = {id = 'content_title', size = 60}, value = entity.title, weight = 10},
      {'textarea', title = 'Teaser', attributes = {id = 'content_teaser', cols = 60, rows = 10}, value = entity.teaser, weight = 20},
      {'textarea', title = 'Body', attributes = {id = 'content_body', cols = 60, rows = 15}, value = entity.body, weight = 30},
      {'checkbox', title = 'Status', attributes = {id = 'content_status'}, value = entity.status, weight = 40},
      {'checkbox', title = 'Promote to frontpage', attributes = {id = 'content_promote'}, value = entity.promote, weight = 50},
      {'markup', title = 'Created on', value = entity.created and format_date(entity.created) or '', weight = 60},
      {'button', attributes = {id = 'save_submit'}, value = 'Save', weight = 70},
    },
  }
end
