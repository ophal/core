local add_js, theme, header, arg, env = add_js, theme, header, arg, env
local modules, tonumber, empty = ophal.modules, tonumber, seawolf.variable.empty
local request_get_body, json, type = request_get_body, require 'dkjson', type
local _SESSION, time, module_invoke_all = _SESSION, os.time, module_invoke_all

local debug = debug

module 'ophal.modules.comment'

local user, db_query, db_last_insert_id

function init()
  db_query = env.db_query
  db_last_insert_id = env.db_last_insert_id
  user = modules.user
end

function route()
  local items = {}

  items.comment_form = {
    title = 'Add a comment',
    page_callback = 'comment_form',
  }

  items['comment/save'] = {
    page_callback = 'save_service',
    format = 'json',
  }

  return items
end

function menu()
  return route()
end

function load(id)
  local rs, err, content

  id = tonumber(id or 0)

  rs, err = db_query('SELECT * FROM comment WHERE id = ?', id)
  if err then
    error(err)
  end

  content = rs:fetch(true)

  if content then
    content.type = 'comment'
    module_invoke_all('comment_load', content)
  end

  return content
end

function comment_form(defaults)
  add_js 'libraries/jquery.min.js'
  add_js 'modules/comment/comment.js'

  return theme{'form', id = 'comment_form',
    attributes = {
      class = 'comment-form',
      ['entity:parent'] = 1,
    },
    elements = {
      {'textarea', description = 'Press ENTER to post.'},
    }
  }
end

function save_service()
  local input, parsed, pos, err, output, account, action, id
--~ 
  --~ if not user.is_logged_in() then
    --~ header('status', 401)
  --~ else
    id = tonumber(arg(2) or '')
    action = empty(id) and 'create' or 'update'
    output = {status = false}

    comment = load(id)

    --~ if not comment_access(comment, action) then
      --~ header('status', 401)
    --~ else

    --~ if action == 'update' and empty(comment) then
      --~ header('status', 404)
      --~ output.error = 'No such comment.'
    --~ else
      output.success = false
      input = request_get_body()
      parsed, pos, err = json.decode(input, 1, nil)
      output.input = parsed
      if err then
        output.error = err
      elseif 'table' == type(parsed) and not empty(parsed) then
        parsed.id = id
        parsed.type = 'comment'

        if type(parsed.status) == 'boolean' then
          parsed.status = parsed.status and 1 or 0
        end
        if type(parsed.promote) == 'boolean' then
          parsed.promote = parsed.promote and 1 or 0
        end

        module_invoke_all('entity_before_save', parsed)

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
    --~ end

  --~ end

  return output
end

function create(entity)
  local rs, err
  rs, err = db_query('INSERT INTO comment(user_id, body, status, created) VALUES(?, ?, ?, ?)', _SESSION.user.id, entity.body, entity.status, time())
  entity.id = db_last_insert_id()
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
