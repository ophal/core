if not ophal.aliases.source then ophal.aliases.source = {} end
if not ophal.aliases.alias then ophal.aliases.alias = {} end
if not ophal.redirects.source then ophal.redirects.source = {} end
if not ophal.redirects.target then ophal.redirects.target = {} end

local explode = require('includes.text').split
local table_shift = require('includes.util').rest
local aliases = ophal.aliases
local redirects = ophal.redirects
local route_set_title, pcall = route_set_title, pcall
local empty = require('includes.util').empty
local projection = require 'includes.projection'
local request_state = require 'includes.request_state'
local projection_touch = projection.touch
local projection_ensure = projection.ensure
local projection_version = projection.version
local projection_is_missing_table = projection.is_missing_table
local projection_rebuild_pending = projection.rebuild_pending
local projection_register_rebuild = projection.register_rebuild
local time = os.time
local ROUTE_ALIAS_INDEX_KEY = 'route_alias_index'
local ROUTE_ALIAS_SOURCE_KEY = 'route_alias_source'
local ROUTE_REDIRECT_INDEX_KEY = 'route_redirect_index'
local ROUTE_REDIRECT_SOURCE_KEY = 'route_redirect_source'
local ROUTE_PROJECTION_KEYS = {
  alias = {index = ROUTE_ALIAS_INDEX_KEY, source = ROUTE_ALIAS_SOURCE_KEY},
  redirect = {index = ROUTE_REDIRECT_INDEX_KEY, source = ROUTE_REDIRECT_SOURCE_KEY},
}

--[[ What each in-memory route table was last built from.

  `ophal.aliases` and `ophal.redirects` are worker state, not request state:
  nothing between requests clears them. What is recorded here is what lets the
  next request decide it has nothing to do. See `route_tables_current()`.
]]
local loaded_routes = {
  alias = {},
  redirect = {},
}

local function route_projection_mark_source(key, version)
  local ok, err = projection_touch(key, version)
  if not ok then
    error(err)
  end
end

local function route_projection_read_version(key)
  local version, err = projection_version(key)

  if err and not projection_is_missing_table(err, 'projection_version') then
    error(err)
  end

  return version
end

--[[ The versions a load is about to build from.

  Read before the rows, so that a write racing the load either lands in the
  rows it returns or moves a version past the one recorded for them. The clock
  is read first for the same reason; `version_settled()` is what uses it.
]]
local function route_projection_observe(kind)
  local keys = ROUTE_PROJECTION_KEYS[kind]

  return {
    at = time(),
    version = route_projection_read_version(keys.index),
    source = route_projection_read_version(keys.source),
  }
end

-- A version is a unix second, so one written during the second a load is
-- running is indistinguishable from the one that load already saw. A load in
-- that position is never reused; a second later the next one settles.
local function version_settled(version, at)
  version = tonumber(version)

  return version == nil or version < at
end

--[[ Whether the in-memory route table still answers for the database.

  Three things move it, and all three are read without touching SQL.

  The index version covers a rebuild and any single-row projection write. The
  source version covers a write during a deferred window, when incremental
  index maintenance is suspended and the index version deliberately stays put:
  the source key is touched on every route write whether the index is
  maintained or not, which is what makes it the dependable half of the pair.

  The marker is the third. A table built from the normalized fallback is only
  reusable while the rebuild meant to replace it is still queued. Once the
  marker lapses with the index version unmoved, no job is coming, and a worker
  that kept trusting its fallback load would never ask for one again -- so a
  fallback load stops being current exactly when the marker does, and the next
  request runs `ensure()` and queues it afresh.

  A site with no projections has no versions and no marker, so it never matches
  here and reloads every request, which is what it did before any of this.
]]
local function route_tables_current(kind, observed)
  local loaded = loaded_routes[kind]

  -- Nothing has been loaded into this worker's table yet.
  if loaded.at == nil then
    return false
  end

  if not loaded.settled then
    return false
  end

  if loaded.fallback
    and projection_rebuild_pending(ROUTE_PROJECTION_KEYS[kind].index) == nil
  then
    return false
  end

  return observed.version == loaded.version and observed.source == loaded.source
end

--[[ Record what the load just built from.

  `observed` is deliberately the reading taken before the load rather than a
  fresh one: a version read after the rows could have moved between the two,
  and recording it would pin stale rows to a current version. The cost is that
  a load which rebuilt the projection inline records the version from before
  its own rebuild and is reloaded once more.
]]
local function route_projection_record_loaded(kind, observed, fallback)
  local loaded = loaded_routes[kind]

  loaded.at = observed.at
  loaded.version = observed.version
  loaded.source = observed.source
  loaded.fallback = fallback == true
  loaded.settled = version_settled(observed.version, observed.at)
    and version_settled(observed.source, observed.at)
end

--[[ Reload a route table if a write since the last load moved its index.

  The loaders guard themselves, so this reads as redundant. It is not: on a site
  with no versions and no pending marker -- an unmigrated one -- their guard can
  never match, and a bare call here would read the whole normalized source a
  second time in a request that phase 12 already loaded. Calling a loader only
  when the index version actually moved is what keeps that site at one load.
]]
local function route_projection_sync()
  local version

  if settings.route_aliases_storage then
    version = route_projection_read_version(ROUTE_ALIAS_INDEX_KEY)
    if version ~= loaded_routes.alias.version then
      route_aliases_load()
    end
  end

  if settings.route_redirects_storage then
    version = route_projection_read_version(ROUTE_REDIRECT_INDEX_KEY)
    if version ~= loaded_routes.redirect.version then
      route_redirects_load()
    end
  end
end

local function route_projection_clear(kind)
  local ok, err = db_connection():try('route.index_clear', kind)

  if not ok then
    if projection_is_missing_table(err, 'route_index') then
      return false
    end

    return nil, err
  end

  return true
end

--[[ Whether incremental maintenance of a route index is suspended.

  While a full rebuild is queued, the index holds a fraction of the site's
  routes and `ensure()` reports it unusable, so nothing reads it. A single-row
  write into it buys nothing -- the rebuild rewrites every row -- and the
  version touch that comes with one would announce a completeness the index does
  not have.
]]
local function route_projection_deferred(kind)
  return projection_rebuild_pending(ROUTE_PROJECTION_KEYS[kind].index) ~= nil
end

local function route_projection_save(kind, source, target, language, http_code, updated_at)
  if route_projection_deferred(kind) then
    return true
  end

  local db = db_connection()
  local ok, err = db:try('route.index_delete', kind, source)

  if not ok then
    if projection_is_missing_table(err, 'route_index') then
      return true
    end

    return nil, err
  end

  ok, err = db:try('route.index_insert',
    kind,
    source,
    target,
    language or 'all',
    http_code,
    updated_at
  )

  if not ok then
    if projection_is_missing_table(err, 'route_index') then
      return true
    end

    return nil, err
  end

  projection_touch(kind == 'alias' and ROUTE_ALIAS_INDEX_KEY or ROUTE_REDIRECT_INDEX_KEY, updated_at)
  return true
end

--[[ The rebuild's per-row write.

  `route_projection_save()` is a DELETE, an INSERT and a version touch, which is
  what a single alias changing needs. A full rebuild needs none of the first and
  none of the last: it has already cleared every row of its kind, so the delete
  has nothing to find, and it touches the index version once at the end, so N
  touches writing the same value are N - 1 statements that change nothing. That
  is what made a rebuild `3N + 4` statements instead of `N + 4`, on a table
  whose size is the number of aliases on the site.
]]
local function route_projection_insert(kind, source, target, language, http_code, updated_at)
  local ok, err = db_connection():try('route.index_insert',
    kind,
    source,
    target,
    language or 'all',
    http_code,
    updated_at
  )

  if not ok then
    if projection_is_missing_table(err, 'route_index') then
      return true
    end

    return nil, err
  end

  return true
end

local function route_projection_delete(kind, source, updated_at)
  if route_projection_deferred(kind) then
    return true
  end

  local ok, err = db_connection():try('route.index_delete', kind, source)

  if not ok then
    if projection_is_missing_table(err, 'route_index') then
      return true
    end

    return nil, err
  end

  projection_touch(kind == 'alias' and ROUTE_ALIAS_INDEX_KEY or ROUTE_REDIRECT_INDEX_KEY, updated_at)
  return true
end

function route_register_alias(source, alias)
  aliases.source[source] = alias
  aliases.alias[alias] = source
end

--[[ Populate `ophal.aliases` from the normalized source, writing nothing.

  Reading the source and rebuilding the projection used to be the same
  function, which meant a request that could not use the projection paid to
  repair it, from inside whatever page happened to notice. They are separate
  now: this is the fallback, and it is what a request takes.

  `on_row` is how the rebuild reuses the read without this function knowing that
  a projection exists.
]]
local function route_aliases_read(on_row)
  local alias
  local rs, err = db_connection():try 'route.aliases_all'

  if not rs then
    error(err)
  end

  for row in rs:rows(true) do
    alias = row.alias
    if (row.language or 'all') ~= 'all' and settings.route_aliases_prepend_language then
      alias = row.language .. '/' .. row.alias
    end
    route_register_alias(row.source, alias)

    if on_row then
      on_row(row)
    end
  end

  return true
end

-- Read plus the projection writes: the rebuild. One clear, one insert per row,
-- and one touch of each version at the end.
local function route_aliases_project()
  local updated_at = time()
  local cleared, clear_err = route_projection_clear('alias')

  if cleared == nil then
    error(clear_err)
  end

  route_aliases_read(function(row)
    route_projection_insert('alias', row.source, row.alias, row.language, nil, updated_at)
  end)

  route_projection_mark_source(ROUTE_ALIAS_SOURCE_KEY, updated_at)
  projection_touch(ROUTE_ALIAS_INDEX_KEY, updated_at)
  return true
end

-- The queue carries a projection key, so the runner finds the rebuild here.
projection_register_rebuild(ROUTE_ALIAS_INDEX_KEY, route_aliases_project)

function route_aliases_load()
  local alias
  local rs, err
  local ok
  local observed = route_projection_observe('alias')

  -- Bootstrap calls this before routing on every request, and `ophal.aliases`
  -- is not cleared between them. Re-reading every alias on the site to arrive
  -- at the table already in memory is the cost this guard removes; it is one
  -- query and `O(aliases)` rows, which is why it read as cheap.
  if route_tables_current('alias', observed) then
    return
  end

  ophal.aliases.source = {}
  ophal.aliases.alias = {}

  ok, err = projection_ensure(ROUTE_ALIAS_INDEX_KEY, route_aliases_project, {
    depends_on = {ROUTE_ALIAS_SOURCE_KEY},
    defer = true,
  })
  if ok == nil then
    error(err)
  elseif ok ~= true then
    -- `ensure` reported the projection unusable rather than rebuilding it.
    -- Read the source and leave the repair to whoever owns it. This branch was
    -- unreachable while the rebuild only ever returned true or raised; calling
    -- the rebuild here is what would have made deferral a no-op on routes, and
    -- routes are the one projection loaded before routing on every request.
    route_aliases_read()
    return route_projection_record_loaded('alias', observed, true)
  end

  rs, err = db_connection():try('route.index_read', 'alias')
  if not rs then
    if projection_is_missing_table(err, 'route_index') then
      route_aliases_read()
      return route_projection_record_loaded('alias', observed, true)
    end
    error(err)
  end

  for row in rs:rows(true) do
    alias = row.target
    if (row.language or 'all') ~= 'all' and settings.route_aliases_prepend_language then
      alias = row.language .. '/' .. row.target
    end
    route_register_alias(row.source, alias)
  end

  route_projection_record_loaded('alias', observed, false)
end

function route_read_alias(id)
  return db_connection():run('route.alias_read', id):fetch(true)
end

function route_create_alias(entity)
  if empty(entity.language) then
    entity.language = 'all'
  end

  local rs
  local db = db_connection()

  if entity.type == nil then entity.type = 'route_alias' end
  local updated_at = time()

  if entity.id then
    rs = db:run('route.alias_create_with_id',
      entity.id,
      entity.source,
      entity.alias,
      entity.language
    )
  else
    rs = db:run('route.alias_create',
      entity.source,
      entity.alias,
      entity.language
    )
    entity.id = db:last_insert_id('route_alias', 'id')
  end

  route_projection_mark_source(ROUTE_ALIAS_SOURCE_KEY, updated_at)
  route_projection_save('alias', entity.source, entity.alias, entity.language, nil, updated_at)
  module_invoke_all('entity_after_save', entity)

  return entity.id
end

function route_update_alias(id, entity)
  local record = route_read_alias(id)
  local original_source = record.source
  local updated_at = time()
  for _, v in pairs{'source', 'alias', 'language'} do
    record[v] = entity[v]
  end
  local rs = db_connection():run('route.alias_update',
    record.source, record.alias, record.language, id)

  route_projection_mark_source(ROUTE_ALIAS_SOURCE_KEY, updated_at)

  if original_source ~= record.source then
    route_projection_delete('alias', original_source, updated_at)
  end

  route_projection_save('alias', record.source, record.alias, record.language, nil, updated_at)

  return rs
end

function route_delete_alias(id)
  local record = route_read_alias(id)
  local updated_at = time()
  local rs = db_connection():run('route.alias_delete', id)

  if record then
    route_projection_mark_source(ROUTE_ALIAS_SOURCE_KEY, updated_at)
    route_projection_delete('alias', record.source, updated_at)
  end

  return rs
end

function route_redirect()
  route_projection_sync()
  local redirect = ophal.redirects.source[request_path()]
  if redirect then
    go_to(redirect[1], redirect[2])
  end
end

function route_register_redirect(source, target, http_code)
  redirects.source[source] = {target, http_code}
  redirects.target[target] = source
end

-- The redirect half of the same split; see `route_aliases_read()`.
local function route_redirects_read(on_row)
  local target
  local rs, err = db_connection():try 'route.redirects_all'

  if not rs then
    error(err)
  end

  for row in rs:rows(true) do
    target = row.target
    if (row.language or 'all') ~= 'all' and settings.route_redirects_prepend_language then
      target = row.language .. '/' .. target
    end
    route_register_redirect(row.source, target, row.type)

    if on_row then
      on_row(row)
    end
  end

  return true
end

local function route_redirects_project()
  local updated_at = time()
  local cleared, clear_err = route_projection_clear('redirect')

  if cleared == nil then
    error(clear_err)
  end

  route_redirects_read(function(row)
    route_projection_insert('redirect', row.source, row.target, row.language, row.type, updated_at)
  end)

  route_projection_mark_source(ROUTE_REDIRECT_SOURCE_KEY, updated_at)
  projection_touch(ROUTE_REDIRECT_INDEX_KEY, updated_at)
  return true
end

projection_register_rebuild(ROUTE_REDIRECT_INDEX_KEY, route_redirects_project)

function route_redirects_load()
  local target
  local rs, err
  local ok
  local observed = route_projection_observe('redirect')

  -- See `route_aliases_load()`; redirects are loaded beside the aliases on the
  -- same request path and answer to the same guard.
  if route_tables_current('redirect', observed) then
    return
  end

  ophal.redirects.source = {}
  ophal.redirects.target = {}

  ok, err = projection_ensure(ROUTE_REDIRECT_INDEX_KEY, route_redirects_project, {
    depends_on = {ROUTE_REDIRECT_SOURCE_KEY},
    defer = true,
  })
  if ok == nil then
    error(err)
  elseif ok ~= true then
    route_redirects_read()
    return route_projection_record_loaded('redirect', observed, true)
  end

  rs, err = db_connection():try('route.index_read', 'redirect')
  if not rs then
    if projection_is_missing_table(err, 'route_index') then
      route_redirects_read()
      return route_projection_record_loaded('redirect', observed, true)
    end
    error(err)
  end

  for row in rs:rows(true) do
    target = row.target
    if (row.language or 'all') ~= 'all' and settings.route_redirects_prepend_language then
      target = row.language .. '/' .. target
    end
    --[[ `http_code` here, `type` in the normalized reader above.

      The projection spells this column `http_code`; `route_redirect` spells it
      `type`. Reading `row.type` off a projection row answers nil, and nil
      reaches `go_to()` as "no status given", which defaults to 302 -- so every
      redirect served from the projection was a 302 whatever it was stored as,
      and a 301 was indistinguishable from a working one until something
      asserted on the status rather than on the location.

      It could not have been noticed before 2026-09-10: no schema created
      `route_redirect`, so this loop had never run.
    ]]
    route_register_redirect(row.source, target, row.http_code)
  end

  route_projection_record_loaded('redirect', observed, false)
end

function route_create_redirect(entity)
  if empty(entity.language) then
    entity.language = 'all'
  end

  local rs
  local db = db_connection()

  --[[ `type` is the HTTP status this redirect answers with, not a name.

    It defaulted to the string 'route_redirect', which reads as an entity type
    and is not one: the column is handed to `route_register_redirect()` as its
    `http_code` and reaches `go_to(target, code)` and then `ngx.status`. A
    string there is not a status. It could never have been noticed, because no
    schema created this table until now and so this function had never run.

    302 rather than 301, matching `go_to()`'s own default: a redirect a site can
    edit out of a table should not be the one browsers cache forever.
  ]]
  if entity.type == nil then entity.type = 302 end
  local updated_at = time()

  if entity.id then
    rs = db:run('route.redirect_create_with_id',
      entity.id,
      entity.source,
      entity.target,
      entity.language,
      entity.type
    )
  else
    rs = db:run('route.redirect_create',
      entity.source,
      entity.target,
      entity.language,
      entity.type
    )
    entity.id = db:last_insert_id('route_redirect', 'id')
  end

  route_projection_mark_source(ROUTE_REDIRECT_SOURCE_KEY, updated_at)
  route_projection_save('redirect', entity.source, entity.target, entity.language, entity.type, updated_at)
  module_invoke_all('entity_after_save', entity)

  return entity.id
end

function route_read_redirect(id)
  return db_connection():run('route.redirect_read', id):fetch(true)
end

function route_update_redirect(id, entity)
  local record = route_read_redirect(id)
  local original_source = record.source
  local updated_at = time()
  for _, v in pairs{'source', 'target', 'language', 'type'} do
    record[v] = entity[v]
  end
  local rs = db_connection():run('route.redirect_update',
    record.source, record.target, record.language, record.type, id)

  route_projection_mark_source(ROUTE_REDIRECT_SOURCE_KEY, updated_at)

  if original_source ~= record.source then
    route_projection_delete('redirect', original_source, updated_at)
  end

  route_projection_save('redirect', record.source, record.target, record.language, record.type, updated_at)

  return rs
end

function route_delete_redirect(id)
  local record = route_read_redirect(id)
  local updated_at = time()
  local rs = db_connection():run('route.redirect_delete', id)

  if record then
    route_projection_mark_source(ROUTE_REDIRECT_SOURCE_KEY, updated_at)
    route_projection_delete('redirect', record.source, updated_at)
  end

  return rs
end

--[[ This request's path, split on `/` and resolved through the alias table.

  Kept in request state rather than in a file upvalue. `route_projection_sync()`
  below can reach SQL, so this function is a yield point, and a worker serving
  another request in the meantime would otherwise leave the two sharing one
  split path -- the first to resume would route the second one's URL.
]]
function route_arg(index)
  local state = request_state.current()
  local arguments = state.route_arguments
  local source, rp

  index = index + 1
  if arguments == nil then
    route_projection_sync()
    rp = request_path()
    source = aliases.alias[rp]
    if source then
      rp = source
    end
    arguments = explode('/', rp ~= '' and rp or settings.site.frontpage)
    state.route_arguments = arguments
  end

  return arguments[index]
end

function route_arg_reset()
  request_state.current().route_arguments = nil
end

local slash = settings.slash

-- The route tree the current request resolved to, remembered in request state
-- for the same reason `route_arg()` is: it is built from `route_arg()`, which
-- yields.
function init_route()
  local state = request_state.current()
  local route_tree, route = state.route_tree, state.route
  local a

  if route_tree == nil and route == nil then
    route_tree = {}

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

    state.route_tree, state.route = route_tree, route
  end
  return route_tree, route
end

function init_route_reset()
  local state = request_state.current()

  state.route_tree, state.route = nil, nil
end

function route_reset_request()
  route_arg_reset()
  init_route_reset()
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

local function route_freeze(routes)
  setmetatable(routes, {
    __newindex = function(_, k)
      error(('route table is frozen; cannot set key "%s" after build'):format(tostring(k)))
    end,
  })
  return routes
end

-- Route cache: stores frozen route table across requests in OpenResty workers.
local cached_routes

function route_cache_get()
  return cached_routes
end

function route_cache_clear()
  cached_routes = nil
end

function route_build_routes()
  local err
  local collected = {}
  local routes = {}

  -- Phase 1: Collect routes in resolved module order
  for _, name in pairs(module_list()) do
    local m = ophal.modules[name]
    if m and m.route then
      local r
      r, err = m.route()
      if err then
        return nil, err
      end
      if type(r) == 'table' then
        collected[#collected + 1] = {name = name, routes = r}
      end
    end
  end

  -- Phase 2: Run route_alter in resolved module order
  for _, entry in ipairs(collected) do
    module_invoke_all('route_alter', entry.name, entry.routes)
  end

  -- Phase 3: Merge with conflict detection, then freeze
  local owners = {}
  for _, entry in ipairs(collected) do
    for path, handler in pairs(entry.routes) do
      route_build_handler(handler, entry.name)
      if owners[path] then
        if type(log_warn) == 'function' then
          log_warn('route conflict', {
            event = 'route_conflict',
            route = path,
            previous_module = owners[path],
            module = entry.name,
          })
        else
          io.stderr:write(
            ('route conflict: "%s" claimed by "%s", overridden by "%s"\n'):format(
              path, owners[path], entry.name
            )
          )
        end
      end
      owners[path] = entry.name
      routes[path] = handler
    end
  end

  routes = route_freeze(routes)
  cached_routes = routes
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
  local html = options.html
  options.attributes = nil
  options.html = nil

  return theme{'a',
    text = text,
    route = url(route, options),
    attributes = attributes,
    html = html,
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
    format = handler.format, -- Root template name same as output format
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
  variables.body = variables.body or 'The requested page could not be found.'

  module_invoke_all('route_not_found_alter', variables)

  header('status', 404)
  page_set_title(variables.header_title, variables.title)

  return variables.body
end
