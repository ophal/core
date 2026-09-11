require 'modules.comment.statements'

local config = settings.comment or {}
if config.render_handler == nil then config.render_handler = 'onload' end
local add_js, theme, header, arg, env, l = add_js, theme, header, route_arg, env, l
local modules, tonumber, empty = ophal.modules, tonumber, require('includes.util').empty
local request_get_body, json, type = request_get_body, require 'includes.json', type
local csrf_validate_request, csrf_denied = csrf_validate_request, csrf_denied
local time, module_invoke_all = os.time, module_invoke_all
local pairs, render_t, url = pairs, render_t, url

local debug = debug

module 'ophal.modules.comment'

local user_mod, db_connection

--[[ Implements hook init().
]]
function init()
  -- Captured per request, not at load: a connection object belongs to the
  -- request that asked for it and raises at its next use once released.
  db_connection = env.db_connection
  user_mod = modules.user
end

--[[ Implements hook entity_render().
]]
function entity_render(entity)
  if not config.entities[entity.type] then return end

  add_js 'modules/comment/comment.js'
  add_js {type = 'settings', namespace = 'entity', {current = {id = entity.id}}}
  add_js {type = 'settings', namespace = 'comment', config}

  local links

  if comment_access(nil, 'create') then
    if entity.links == nil then entity.links = {} end
    links = entity.links
    links[1 + #links] = l(
      'Add a new comment',
      'comment/create/' .. entity.id,
      {attributes = {rel = 'nofollow'}}
    )
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

  rs = db_connection():run('comment.load', id)
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

  rs = db_connection():with('comment.load_by_field', field_name):run(value)

  for row in rs:rows(true) do
    rows[1 + #rows] = row
  end

  return rows
end

function comment_access(entity, action)
  local account = user_mod.current()

  if user_mod.access 'administer comments' then
    return true
  end

  if action == 'create' then
    return user_mod.access 'post comments'
  elseif action == 'update' then
    return user_mod.access 'edit own comments' and entity.user_id == account.id
  elseif action == 'read' then
    return user_mod.access 'access comments'
  elseif action == 'delete' then
    return user_mod.access 'delete own comments' and entity.user_id == account.id
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
  --[[ `list` is a local, and it was not.

    Inside `module()` an unqualified assignment becomes a field on the module
    table, so one visitor's comment list stayed on `ophal.modules.comment.list`
    for the worker's lifetime and a request that failed before the assignment
    below rendered the previous request's comments. Same class as
    `modules/file`'s `load_by_field` in stage 8.5 and `save_service`'s own
    `comment` -- and `includes/module.lua` now seals a jailed module's table
    after it loads, so a fifth instance raises at the line instead of leaking.

    `entity` and `err` went with it. `entity` was declared and never used, and
    `err` named a second return `load_multiple_by` does not have.
  ]]
  local output, entity_id, list

  output = {success = false}

  -- `nil`, not a bare `comment`, which is a module-table read that has always
  -- resolved to nothing. The `read` arm of `comment_access` never looks at the
  -- entity; `entity_render` above spells the same call this way.
  if not comment_access(nil, 'read') then
    header('status', 401)
  else
    --[[ A number, not the string the route hands over.

      Binding preserves a value's type and lets the server type-check the
      comparison, so `entity_id = ?` with a string reaches PostgreSQL as
      `bigint = text`, which has no operator and is refused. SQLite and MySQL
      both coerce it, which is why this read the route argument raw while every
      other service in this file already called `tonumber` -- and why nothing
      noticed until stage 8.7 ran the fetch service on a third backend.
    ]]
    entity_id = tonumber(arg(2) or '')
    if entity_id then
      --[[ One return value. `load_multiple_by` ends in
        `db:with(...):run(value)`, and a `Statement` carries only `run` and
        `sql` -- so a database error here is a raise, which `theme.json`
        answers 500. `Connection:try()` is the shape if a recoverable error is
        ever wanted; the `if err then` branch that stood here could not run.
      ]]
      list = load_multiple_by('entity_id', entity_id)

      for k, row in pairs(list) do
        list[k].rendered = render_t{'comment', entity = row,
          account = user_mod.load(row.user_id),
          author = theme{'author', entity = row},
        }
      end
      --[[ A list, and it says so.

        dkjson writes `[]` for an empty table and cjson writes `{}`, so an
        entity with no comments would answer `"list":{}` on one backend and
        `"list":[]` on the other. A browser doing `for (const c of list)`
        works on the first and throws on the second, which makes it a bug
        that appears only on a page with nothing on it.
      ]]
      output.list = json.array(list)
      output.success = true
    end
  end

  return output
end

function save_service()
  local _, input, parsed, err, output, account, action, id

  id = tonumber(arg(2) or '')
  action = empty(id) and 'create' or 'update'
  output = {success = false}

  input = request_get_body()
  parsed, err = json.decode(input)

  --[[ A body that will not parse is the client's error, and it is answered as
    one. It used to answer **200**, and worse than that: `request_get_body()`
    is nil for a method with no body, `dkjson.decode(nil, ...)` *raises* on it,
    and the dispatcher's pcall turned the raise into an error string carrying
    a dkjson source path -- which `theme.json` rendered into the body. So
    `GET /comment/save` disclosed the filesystem layout at HTTP 200, and
    because the status was 200 the cache layer marked it `public` with a
    validator, which is what let a shared cache keep it.

    `comment/save` is where this was reachable anonymously: `content/save`
    answers 401 before it looks at a body, and `tag/save` 404s. The shim
    refuses a non-string at source, so the raise is gone; the status is what
    makes the answer honest.
  ]]
  if err then
    header('status', 400)
    output.error = err
  elseif not csrf_validate_request(parsed) then
    csrf_denied(output)
  else
    --[[ Loaded only for an update, and its existence checked before access.

      `local`, and it was not: inside `module()` an unqualified assignment
      becomes a field on the module table, so one request's comment stayed there
      for the worker's lifetime and was readable by the next -- the same class
      as `modules/file`'s `load_by_field` in stage 8.5.

      The order was wrong too, and worse than the 401 it looked like.
      `comment_access(entity, 'update')` reads `entity.user_id`, and `load()`
      answers nil for an id that is not there, so `comment/save/999999` *raised*
      on that index and the module dispatcher turned the raise into a 200 whose
      JSON body carried the file and line of the error. Existence first, the way
      `modules/content` and `modules/tag` already do it.

      Only a caller holding `edit own comments` reached it: `administer
      comments` returns true before the comparison, and without the permission
      the `and` short-circuits before it. That is why a module with no test
      profile kept it this long.
    ]]
    local comment

    if action == 'update' then
      comment = load(id)
    end

    if action == 'update' and empty(comment) then
      header('status', 404)
      output.error = 'No such comment.'
    elseif not comment_access(comment, action) then
      header('status', 401)
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

  local db = db_connection()

  if entity.id then
    db:run('comment.create_with_id',
      entity.id,
      entity.entity_id,
      entity.parent_id,
      entity.user_id or user_mod.current().id,
      entity.language or 'en',
      entity.body,
      entity.created or time(),
      entity.status,
      -- 0 rather than false: see the note in `modules/content`'s create().
      entity.sticky or 0
    )
  else
    db:run('comment.create',
      entity.entity_id,
      entity.parent_id,
      entity.user_id or user_mod.current().id,
      entity.language or 'en',
      entity.body,
      entity.created or time(),
      entity.status,
      entity.sticky or 0
    )
    entity.id = db:last_insert_id('comment', 'id')
  end

  module_invoke_all('entity_after_save', entity)

  return entity.id
end

function update(entity)
  local rs = db_connection():run('comment.update',
    entity.body, entity.status, time(), entity.id)

  module_invoke_all('entity_after_save', entity)

  return rs
end
