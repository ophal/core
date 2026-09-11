local _M = {
  entity_type = 'content',
}
ophal.modules[_M.entity_type] = _M

local config = settings.content or {}
local env, theme, tonumber, ceil = env, theme, tonumber, math.ceil
local tinsert, tconcat, pairs, debug = table.insert, table.concat, pairs, debug
local ipairs = ipairs
local pager, l, page_set_title, arg = pager, l, page_set_title, route_arg
local pager_current_page = pager_current_page
local tonumber, format_date = tonumber, format_date
local empty, add_js, ophal, t = require('includes.util').empty, add_js, ophal, t
local header, json, type, time = header, require 'includes.json', type, os.time
local print_t, require, modules = print_t, require, ophal.modules
local module_invoke_all, request_get_body = module_invoke_all, request_get_body
local csrf_validate_request, csrf_denied = csrf_validate_request, csrf_denied
local error = error
local projection = require 'includes.projection'

require 'modules.content.statements'
local projection_touch = projection.touch
local projection_rebuild_pending = projection.rebuild_pending
local projection_register_rebuild = projection.register_rebuild
local projection_ensure = projection.ensure
local projection_cached_value = projection.cached_value
local projection_is_missing_table = projection.is_missing_table

local set_global = set_global

module 'ophal.modules.content'

local user_mod, db_connection

--[[ The front page in its two scopes, as statement names rather than a WHERE
  fragment formatted into one body per request. An anonymous visitor sees
  published rows; a signed-in one sees every promoted row.
]]
local FRONTPAGE = {
  public_count = {
    all = 'content.public_count_all',
    published = 'content.public_count_published',
  },
  public_rows = {
    all = 'content.public_rows_all',
    published = 'content.public_rows_published',
  },
  count = {
    all = 'content.frontpage_count_all',
    published = 'content.frontpage_count_published',
  },
  rows = {
    all = 'content.frontpage_rows_all',
    published = 'content.frontpage_rows_published',
  },
}
local CONTENT_PUBLIC_KEY = 'content_public'
local CONTENT_SOURCE_KEY = 'content_source'

local function copy_row(row)
  local copied = {}

  for key, value in pairs(row or {}) do
    copied[key] = value
  end

  return copied
end

local function copy_rows(rows)
  local copied = {}

  for i = 1, #(rows or {}) do
    copied[i] = copy_row(rows[i])
  end

  return copied
end

local function content_projection_mark_source(version)
  local ok, err = projection_touch(CONTENT_SOURCE_KEY, version)

  if not ok then
    error(err)
  end
end

--[[ Implements hook init().
]]
function init()
  -- Captured per request, not at load: a connection object belongs to the
  -- request that asked for it and raises at its next use once released.
  db_connection = env.db_connection
  user_mod = modules.user
end

--[[ Implements hook route().
]]
function route()
  local items = {}
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

  rs = db_connection():run('content.load', id)

  return rs:fetch(true)
end

-- The row write on its own. A full rebuild uses this directly: it has already
-- emptied `content_public`, so the delete in `content_projection_write()` finds
-- nothing, and it touches the version once at the end, so N touches writing the
-- same value are N - 1 statements that change nothing. That is the difference
-- between a rebuild costing `3N + 3` statements and `N + 3`.
local function content_projection_insert(entity, updated_at)
  local ok, err = db_connection():try('content.public_insert',
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

  return true
end

--[[ Whether incremental maintenance of `content_public` is suspended.

  While a full rebuild is queued and has not run, the projection is a fraction
  of the answer and `ensure()` reports it unusable, so nothing reads it. Writing
  single rows into it in the meantime buys nothing -- the rebuild rewrites every
  row -- and touching its version would be a lie: a version is the only thing
  `ensure()` compares, so one incremental touch would announce a completeness
  the projection does not have and send every reader to a table holding one row.
]]
local function content_projection_deferred()
  return projection_rebuild_pending(CONTENT_PUBLIC_KEY) ~= nil
end

local function content_projection_write(entity, version)
  local ok, err
  local updated_at = tonumber(version) or time()

  if content_projection_deferred() then
    return true
  end

  ok, err = db_connection():try('content.public_delete', entity.id)
  if not ok then
    if projection_is_missing_table(err, 'content_public') then
      return true
    end

    return nil, err
  end

  ok, err = content_projection_insert(entity, updated_at)
  if not ok then
    return nil, err
  end

  projection_touch(CONTENT_PUBLIC_KEY, updated_at)
  return true
end

local function content_projection_delete(id, version)
  local ok, err

  if content_projection_deferred() then
    return true
  end

  ok, err = db_connection():try('content.public_delete', id)

  if not ok then
    if projection_is_missing_table(err, 'content_public') then
      return true
    end

    return nil, err
  end

  projection_touch(CONTENT_PUBLIC_KEY, version)
  return true
end

local function content_projection_rebuild_all()
  local db = db_connection()
  local rs, err = db:run('content.all')
  local row
  local ok
  -- One version for the whole rebuild. Letting each write fall back to its own
  -- `time()` can stamp the source a second ahead of the projection, which reads
  -- as stale and rebuilds again on the next request.
  local updated_at = time()

  ok, err = db:try('content.public_clear')
  if not ok then
    if projection_is_missing_table(err, 'content_public') then
      return false
    end

    error(err)
  end

  for row in rs:rows(true) do
    ok, err = content_projection_insert(row, updated_at)
    if not ok then
      error(err)
    end
  end

  -- The rebuild has just read `content`, so it records a source version too, the
  -- way `route_aliases_project()` does. A site installed from a dump or by
  -- the installer never writes `content_source` through the entity hooks, and an
  -- absent version row is re-queried every time the miss cache lapses: once
  -- every `projection_version_miss_ttl` seconds, per worker, on every anonymous
  -- page.
  content_projection_mark_source(updated_at)
  projection_touch(CONTENT_PUBLIC_KEY, updated_at)
  return true
end

-- The queue carries a projection key, so the runner finds the rebuild here.
projection_register_rebuild(CONTENT_PUBLIC_KEY, content_projection_rebuild_all)

local function content_projection_ready()
  local ok, err = projection_ensure(CONTENT_PUBLIC_KEY, content_projection_rebuild_all, {
    depends_on = {CONTENT_SOURCE_KEY},
    defer = true,
  })

  if ok == nil then
    error(err)
  end

  return ok
end

--[[ Read one entity from the projection.

  The second return value is whether the projection was usable at all, which is
  not the same question as whether the row was found. `load()` needs both: a
  miss in a current projection is worth backfilling, and a miss in one whose
  rebuild has not happened yet is not.
]]
local function load_projection(id)
  local row, err

  if not content_projection_ready() then
    return nil, false
  end

  row, err = projection_cached_value(
    CONTENT_PUBLIC_KEY,
    ('entity:%s'):format(id),
    function()
      local rs, query_err = db_connection():try('content.public_load', id)
      if not rs then
        return nil, query_err
      end

      return rs:fetch(true)
    end
  )
  if err then
    if projection_is_missing_table(err, 'content_public') then
      return nil, false
    end

    error(err)
  end

  if row then
    return copy_row(row), true
  end

  return nil, true
end

function load(id)
  local entity, projection_usable

  id = tonumber(id or 0)
  entity, projection_usable = load_projection(id)

  if not entity then
    entity = load_legacy(id)

    -- Backfill only into a projection that is otherwise current. Writing one
    -- row into a projection that is waiting to be rebuilt would touch
    -- `content_public`'s version, and a version is the only thing `ensure()`
    -- compares: the projection would read as fresh while holding a fraction of
    -- its rows, and the front page would render from that fraction. The
    -- rebuild rewrites every row anyway, so there is nothing to preserve here.
    if entity and projection_usable then
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
  local _, input, parsed, err, output, account, action, id
  local entity

  if not user_mod.is_logged_in() then
    header('status', 401)
  else
    id = tonumber(arg(2) or '')
    action = empty(id) and 'create' or 'update'
    output = {}

    -- Only an update has an entity to load. A create used to call `load(nil)`,
    -- which resolves to id 0 and buys two certain misses: one in
    -- `content_public` and one in `content`. Nothing here wants it --
    -- `entity_access(entity, 'create')` never looks at the entity, and the
    -- `empty(entity)` branch below is update-only.
    if action == 'update' then
      entity = load(id)
    end

    output.success = false
    input = request_get_body()
    parsed, err = json.decode(input)
    if err then
      -- A body that will not parse is the client's error. This answered 200
      -- until 2026-09-10, which is what let the same shape on `comment/save`
      -- be marked publicly cacheable.
      header('status', 400)
      output.error = err
    elseif not csrf_validate_request(parsed) then
      csrf_denied(output)
    -- Existence is checked before access because the access answer depends on
    -- the entity: the update and delete arms of `entity_access()` compare
    -- `entity.user_id` against the account, and `load()` returns nil for an id
    -- that is not there. In the other order, `content/save/9999` raised on that
    -- index, and the module dispatcher turned the raise into a 200 whose JSON
    -- body carried the file and line of the error rather than a 404. Only a
    -- user holding `edit own content` ever reached it -- `administer content`
    -- returns true before the comparison, and without the permission the `and`
    -- short-circuits before it -- which is why it survived this long.
    elseif action == 'update' and empty(entity) then
      header('status', 404)
      output.error = 'No such content.'
    elseif not _M.entity_access(entity, action) then
      header('status', 401)
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
          _, err = update(parsed)
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
  local updated_at = time()

  if entity.type == nil then entity.type = 'content' end

  local db = db_connection()

  if entity.id then
    db:run('content.create_with_id',
      entity.id,
      entity.user_id or user_mod.current().id,
      entity.title,
      entity.teaser,
      entity.body,
      entity.status,
      -- 0 rather than false. Every flag column in the schema is `smallint` on
      -- PostgreSQL and `BOOLEAN` -- which is an integer -- on SQLite, and
      -- PostgreSQL type-checks a bound parameter rather than coercing it: a
      -- Lua boolean here is `column "x" is of type smallint but expression is
      -- of type boolean`. SQLite and MySQL both take it, so this was invisible
      -- until stage 8.7 ran the authoring path on a third backend.
      entity.promote or 0,
      entity.created or time()
    )
  else
    db:run('content.create',
      entity.user_id or user_mod.current().id,
      entity.title,
      entity.teaser,
      entity.body,
      entity.status,
      entity.promote or 0,
      entity.created or time()
    )
    entity.id = db:last_insert_id('content', 'id')
  end

  content_projection_mark_source(updated_at)
  module_invoke_all('entity_after_save', entity)

  return entity.id
end

function update(entity)
  local updated_at = time()
  local rs = db_connection():run('content.update',
    entity.title,
    entity.teaser,
    entity.body,
    entity.status,
    entity.promote,
    updated_at,
    entity.id
  )

  content_projection_mark_source(updated_at)
  module_invoke_all('entity_after_save', entity)

  return rs
end

function delete(entity)
  local updated_at = time()
  local rs = db_connection():run('content.delete', entity.id)

  content_projection_mark_source(updated_at)
  module_invoke_all('entity_after_delete', entity)

  return rs
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
  local entities
  local rs, err, count, current_page, ipp, num_pages
  local use_projection = content_projection_ready()
  -- Which of the two scopes this visitor sees. It picks the statement and it is
  -- part of the payload cache key, so it is derived once rather than twice.
  local scope = user_mod.is_logged_in() and 'all' or 'published'

  ipp = config.items_per_page or 10

  -- Count rows
  if use_projection then
    count, err = projection_cached_value(
      CONTENT_PUBLIC_KEY,
      ('frontpage:count:%s'):format(scope),
      function()
        local count_rs, query_err =
          db_connection():try(FRONTPAGE.public_count[scope])

        if not count_rs then
          return nil, query_err
        end

        return (count_rs:fetch(true) or {}).total
      end
    )
    if err then
      if projection_is_missing_table(err, 'content_public') then
        use_projection = false
      else
        error(err)
      end
    end
  end

  if not use_projection then
    rs = db_connection():run(FRONTPAGE.count[scope])
    count = (rs:fetch(true) or {}).total
  end

  num_pages = ceil(count/ipp)

  -- Calculate current page. Clamping happens here, after the count, because
  -- `current_page` becomes part of the payload cache key below.
  current_page = pager_current_page((env._GET or {}).page, num_pages)

  -- Render list
  if use_projection then
    entities, err = projection_cached_value(
      CONTENT_PUBLIC_KEY,
      ('frontpage:rows:%s:%s:%s'):format(scope, current_page, ipp),
      function()
        local rows_rs, query_err = db_connection():try(
          FRONTPAGE.public_rows[scope],
          (current_page - 1) * ipp,
          ipp
        )

        if not rows_rs then
          return nil, query_err
        end

        return rows_rs:all(true)
      end
    )
    if err then
      if projection_is_missing_table(err, 'content_public') then
        use_projection = false
      else
        error(err)
      end
    end
  end

  if not use_projection then
    rs = db_connection():run(
      FRONTPAGE.rows[scope],
      (current_page - 1) * ipp,
      ipp
    )
  end

  if use_projection then
    entities = copy_rows(entities or {})
  else
    entities = {}
    for row in rs:rows(true) do
      -- No backfill here either, and for the reason given in `load()`: this
      -- branch runs precisely when the projection is not usable, so writing one
      -- page of rows into it would stamp a completeness it does not have.
      tinsert(entities, row)
    end
  end

  for _, row in ipairs(entities) do
    tinsert(rows, function () print_t{'content_teaser', entity = row} end)
  end

  if num_pages > 1 then
    page_set_title(("%s (page %s)"):format(t('Frontpage'), current_page))
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
