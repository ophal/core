local config = settings.comment
local add_js, theme, header, arg, env, l = add_js, theme, header, route_arg, env, l
local modules, tonumber, empty = ophal.modules, tonumber, seawolf.variable.empty
local request_get_body, json, type = request_get_body, require 'dkjson', type
local _SESSION, time, module_invoke_all = _SESSION, os.time, module_invoke_all
local pairs, render_t, url = pairs, render_t, url

local debug = debug

module 'ophal.modules.comment'

local user, db_query, db_last_insert_id

--[[ Implements hook init().
]]
function init()
  db_query = env.db_query
  db_last_insert_id = env.db_last_insert_id
  user = modules.user
end

--[[ Implements hook entity_render().
]]
function entity_render(entity)
  if not config.entities[entity.type] then return end

  add_js 'modules/comment/comment.js'
  add_js {type = 'settings', namespace = 'content', {current = {id = entity.id}}}

  local links

  if comment_access(nil, 'create') then
    if entity.links == nil then entity.links = {} end
    links = entity.links
    links[1 + #links] = l('Add a new comment', 'comment/create/' .. entity.id)
  end
end

--[[ Implements hook route().
]]
function route()
  local items = {}

  items['comment/create'] = {
    title = 'Add a comment',
    page_callback = 'create_form',
  }

  items['comment/save'] = {
    page_callback = 'save_service',
    format = 'json',
  }

  items['comment/fetch'] = {
    page_callback = 'fetch_service',
    format = 'json',
  }

  return items
end

function load(id)
  local rs, err, entity

  id = tonumber(id or 0)

  rs, err = db_query('SELECT * FROM comment WHERE id = ?', id)
  if err then
    error(err)
  end

  entity = rs:fetch(true)

  if entity then
    entity.type = 'comment'
    module_invoke_all('entity_load', entity)
  end

  return entity
end

function load_multiple_by(field_name, value)
  local rs, err
  local rows = {}

  rs, err = db_query('SELECT * FROM comment WHERE ' .. field_name .. ' = ?', value)

  for row in rs:rows(true) do
    rows[1 + #rows] = row
  end

  return rows, err
end

function comment_access(entity, action)
  local account = _SESSION.user

  if user.access 'administer comments' then
    return true
  end

  if action == 'create' then
    return user.access 'post comments'
  elseif action == 'update' then
    return user.access 'edit own comments' and entity.user_id == account.id
  elseif action == 'read' then
    return user.access 'access comments'
  elseif action == 'delete' then
    return user.access 'delete own comments' and entity.user_id == account.id
  end
end

function create_form()
  local entity_id, parent_id

  add_js 'modules/comment/comment.js'

  entity_id = tonumber(arg(2) or '')
  parent_id = tonumber(arg(3) or '')

  if entity_id then
    return theme{'form', id = 'comment_create_form',
      attributes = {
        class = 'comment-form',
        ['entity:entity_id'] = entity_id,
        ['entity:parent_id'] = parent_id,
      },
      elements = {
        {'textarea', description = 'Press ENTER to post.'},
      }
    }
  else
    header('status', 401)
    return ''
  end
end

function fetch_service()
  local output, entity, entity_id, err

  output = {success = false}

  if not comment_access(comment, 'read') then
    header('status', 401)
  else
    entity_id = arg(2)
    if entity_id then
      list, err = load_multiple_by('entity_id', entity_id)
      if err then
        output.error = err
      else
        for k, row in pairs(list) do
          list[k].rendered = render_t{'comment', entity = row,
            account = user.load(row.user_id)
          }
        end
        output.list = list
        output.success = true
      end
    end
  end

  return output
end

function save_service()
  local _, input, parsed, pos, err, output, account, action, id
  
  id = tonumber(arg(2) or '')
  action = empty(id) and 'create' or 'update'
  output = {success = false}

  comment = load(id)

  if not comment_access(comment, action) then
    header('status', 401)
  elseif action == 'update' and empty(comment) then
    header('status', 404)
    output.error = 'No such comment.'
  else
    output.success = false
    input = request_get_body()
    parsed, pos, err = json.decode(input, 1, nil)
    if err then
      output.error = err
    elseif
      'table' == type(parsed) and
      not empty(parsed) and
      not empty(parsed.entity_id)
    then
      parsed.id = id
      parsed.type = 'comment'

      parsed.status = 1 -- Make comments public by default

      _, err = module_invoke_all('entity_before_save', parsed)

      if err then
        output.error = err
      else
        if action == 'create' then
          id, err = create(parsed)
        elseif action == 'update' then
          _, err = update(parsed)
        end

        if err then
          output.error = err
        else
          output.id = id
          output.return_path = url('content/' .. parsed.entity_id)
          output.success = true
        end
      end
    end
  end

  return output
end

function create(entity)
  local rs, err

  if entity.type == nil then entity.type = 'comment' end

  if entity.id then
    rs, err = db_query([[
INSERT INTO comment(id, entity_id, parent_id, user_id, language, body, created, status, sticky)
VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?)]],
      entity.id,
      entity.entity_id,
      entity.parent_id,
      entity.user_id or _SESSION.user.id,
      entity.language or 'en',
      entity.body,
      entity.created or time(),
      entity.status,
      entity.sticky or false
    )
  else
    rs, err = db_query([[
INSERT INTO comment(entity_id, parent_id, user_id, language, body, created, status, sticky)
VALUES(?, ?, ?, ?, ?, ?, ?, ?)]],
      entity.entity_id,
      entity.parent_id,
      entity.user_id or _SESSION.user.id,
      entity.language or 'en',
      entity.body,
      entity.created or time(),
      entity.status,
      entity.sticky or false
    )
    entity.id = db_last_insert_id()
  end

  if not err then
    module_invoke_all('entity_after_save', entity)
  end
  return entity.id, err
end

function update(entity)
  local rs, err
  rs, err = db_query('UPDATE comment SET body = ?, status = ?, changed = ? WHERE id = ?', entity.body, entity.status, time(), entity.id)
  if not err then
    module_invoke_all('entity_after_save', entity)
  end
  return rs, err
end
