-- Unit tests for route/content projection foundations.

do
  local root = io.popen('pwd'):read('*l')
  local vendor_root = root .. '/tests/smoke/vendor'
  local vendor_share = vendor_root .. '/unpack/usr/share/lua/5.1'
  local vendor_lib = io.popen("find '" .. vendor_root .. "/unpack/usr/lib' -path '*/lua/5.1' -type d 2>/dev/null | sed -n '1p'"):read('*l')

  package.path = table.concat({
    root .. '/?.lua',
    root .. '/?/init.lua',
    vendor_root .. '/?.lua',
    vendor_root .. '/?/init.lua',
    vendor_share .. '/?.lua',
    vendor_share .. '/?/init.lua',
    package.path,
  }, ';')

  if vendor_lib and vendor_lib ~= '' then
    package.cpath = vendor_lib .. '/?.so;' .. package.cpath
  end
end

seawolf = require 'seawolf'
seawolf.__build('text', 'variable', 'contrib', 'fs')

local pass_count, fail_count = 0, 0

local function assert_eq(label, got, expected)
  if got == expected then
    pass_count = pass_count + 1
    io.write(('  ok %s\n'):format(label))
  else
    fail_count = fail_count + 1
    io.write(('  FAIL %s: expected %s, got %s\n'):format(
      label, tostring(expected), tostring(got)))
  end
end

local function assert_match(label, got, pattern)
  if tostring(got):match(pattern) then
    pass_count = pass_count + 1
    io.write(('  ok %s\n'):format(label))
  else
    fail_count = fail_count + 1
    io.write(('  FAIL %s: %q did not match %q\n'):format(
      label, tostring(got), pattern))
  end
end

local function rows_result(items)
  local index = 0
  return {
    fetch = function(_, named)
      index = index + 1
      return items[index]
    end,
    rows = function(_, named)
      local row_index = 0
      return function()
        row_index = row_index + 1
        return items[row_index]
      end
    end,
  }
end

local function new_projection_state()
  return {
    queries = {},
    versions = {},
    route_index = {
      alias = {},
      redirect = {},
    },
    route_alias = {},
    route_redirect = {},
    content_public = {},
    content_rows = {},
  }
end

local function make_db_query(state)
  local function record(sql, params)
    state.queries[#state.queries + 1] = {
      sql = sql,
      params = params or {},
    }
  end

  return function(sql, ...)
    local args = {...}
    local row

    record(sql, args)

    if sql == 'SELECT version FROM projection_version WHERE projection_key = ?' then
      row = state.versions[args[1]]
      if row == nil then
        return rows_result({})
      end
      return rows_result({{row}})
    elseif sql == 'DELETE FROM projection_version WHERE projection_key = ?' then
      state.versions[args[1]] = nil
      return rows_result({})
    elseif sql == 'INSERT INTO projection_version(projection_key, version, updated_at) VALUES(?, ?, ?)' then
      state.versions[args[1]] = args[2]
      return rows_result({})
    elseif sql == "SELECT * FROM route_index WHERE kind = 'alias'" then
      return rows_result(state.route_index.alias)
    elseif sql == "SELECT * FROM route_index WHERE kind = 'redirect'" then
      return rows_result(state.route_index.redirect)
    elseif sql == 'SELECT * FROM route_alias' then
      return rows_result(state.route_alias)
    elseif sql == 'SELECT * FROM route_redirect' then
      return rows_result(state.route_redirect)
    elseif sql == 'DELETE FROM route_index WHERE kind = ? AND source = ?' then
      local bucket = state.route_index[args[1]]
      local kept = {}
      for _, item in ipairs(bucket or {}) do
        if item.source ~= args[2] then
          kept[#kept + 1] = item
        end
      end
      state.route_index[args[1]] = kept
      return rows_result({})
    elseif sql:match('^INSERT INTO route_index') then
      local bucket = state.route_index[args[1]]
      bucket[#bucket + 1] = {
        kind = args[1],
        source = args[2],
        target = args[3],
        language = args[4],
        http_code = args[5],
      }
      return rows_result({})
    elseif sql == 'SELECT * FROM content_public WHERE id = ?' then
      row = state.content_public[tonumber(args[1])]
      return rows_result(row and {row} or {})
    elseif sql:match('^SELECT count%(%*%) FROM content_public') then
      local count = 0
      for _, item in pairs(state.content_public) do
        if item.promote == 1 and (sql:find('AND status = 1', 1, true) == nil or item.status == 1) then
          count = count + 1
        end
      end
      return rows_result({{count}})
    elseif sql:match('^SELECT %* FROM content_public') then
      local rows = {}
      for _, item in pairs(state.content_public) do
        if item.promote == 1 and (sql:find('AND status = 1', 1, true) == nil or item.status == 1) then
          rows[#rows + 1] = item
        end
      end
      table.sort(rows, function(a, b)
        return (a.created or 0) > (b.created or 0)
      end)
      return rows_result(rows)
    elseif sql == 'SELECT * FROM content WHERE id = ?' then
      row = state.content_rows[tonumber(args[1])]
      return rows_result(row and {row} or {})
    elseif sql == 'SELECT * FROM content' then
      local rows = {}
      for _, item in pairs(state.content_rows) do
        rows[#rows + 1] = item
      end
      return rows_result(rows)
    elseif sql:match('^SELECT count%(%*%) FROM content WHERE') then
      local count = 0
      for _, item in pairs(state.content_rows) do
        if item.promote == 1 and (sql:find('AND status = 1', 1, true) == nil or item.status == 1) then
          count = count + 1
        end
      end
      return rows_result({{count}})
    elseif sql:match('^SELECT %* FROM content WHERE promote = 1') then
      local rows = {}
      for _, item in pairs(state.content_rows) do
        if item.promote == 1 and (sql:find('AND status = 1', 1, true) == nil or item.status == 1) then
          rows[#rows + 1] = item
        end
      end
      table.sort(rows, function(a, b)
        return (a.created or 0) > (b.created or 0)
      end)
      return rows_result(rows)
    elseif sql == 'DELETE FROM content_public WHERE id = ?' then
      state.content_public[tonumber(args[1])] = nil
      return rows_result({})
    elseif sql == 'DELETE FROM content_public' then
      state.content_public = {}
      return rows_result({})
    elseif sql:match('^INSERT INTO content_public') then
      state.content_public[tonumber(args[1])] = {
        id = args[1],
        user_id = args[2],
        language = args[3],
        title = args[4],
        teaser = args[5],
        body = args[6],
        created = args[7],
        changed = args[8],
        status = args[9],
        promote = args[10],
        route = args[11],
        updated_at = args[12],
      }
      return rows_result({})
    end

    return rows_result({})
  end
end

local function query_count(state, pattern)
  local count = 0
  for _, query in ipairs(state.queries) do
    if query.sql:match(pattern) then
      count = count + 1
    end
  end
  return count
end

local function setup_route_env(state)
  ophal = {
    aliases = {source = {}, alias = {}},
    redirects = {source = {}, target = {}},
    modules = {},
  }
  settings = {
    slash = '/',
    site = {frontpage = 'lorem_ipsum'},
    route_aliases_prepend_language = false,
    route_redirects_prepend_language = false,
  }
  db_query = make_db_query(state)
  db_last_insert_id = function() return 1 end
  module_invoke_all = function() end
  request_path = function() return '' end
  go_to = function() end
  package.loaded['includes.projection'] = nil
  dofile('includes/route.lua')
end

local function setup_content_env(state)
  local user_module = {
    current = function() return {id = 1} end,
    is_logged_in = function() return false end,
    access = function() return false end,
    load = function(id) return {id = id or 0} end,
  }

  settings = {
    content = {
      items_per_page = 10,
    },
  }
  ophal = {
    modules = {
      user = user_module,
    },
  }
  env = {
    db_query = make_db_query(state),
    db_limit = function() return ' LIMIT ?, ?' end,
    db_last_insert_id = function() return 1 end,
  }
  db_query = env.db_query
  _GET = {}
  header = function() end
  pager = function() return {} end
  l = function(text) return text end
  t = function(text) return text end
  page_set_title = function() end
  route_arg = function(index)
    if index == 1 then
      return nil
    end
  end
  add_js = function() end
  theme = setmetatable({}, {__call = function() return '' end})
  request_get_body = function() return '' end
  csrf_validate_request = function() return true end
  csrf_denied = function() end
  print_t = function() end
  set_global = function() end
  module_invoke_all = function() end
  package.loaded['includes.projection'] = nil
  package.loaded['ophal.modules.content'] = nil
  dofile('modules/content/init.lua')
  ophal.modules.content = package.loaded['ophal.modules.content'] or ophal.modules.content
  ophal.modules.content.init()
  return ophal.modules.content
end

io.write '\n-- core migrations registry --\n'

do
  local migrations = dofile('includes/migrations.lua')

  assert_eq('core_migration_count', #migrations, 3)
  assert_eq('core_migration_route_index', migrations[1].id, '001_route_index')
  assert_eq('core_migration_content_public', migrations[2].id, '002_content_public')
  assert_eq('core_migration_projection_version', migrations[3].id, '003_projection_version')
end

io.write '\n-- route projections --\n'

do
  local state = new_projection_state()
  state.versions.route_alias_index = 100
  state.route_index.alias = {
    {source = 'content/1', target = 'hello-world', language = 'all'},
  }
  state.versions.route_redirect_index = 101
  state.route_index.redirect = {
    {source = 'old-path', target = 'new-path', language = 'all', type = 301},
  }

  setup_route_env(state)
  route_aliases_load()
  route_redirects_load()

  assert_eq('route_projection_alias_loaded', ophal.aliases.source['content/1'], 'hello-world')
  assert_eq('route_projection_redirect_target', ophal.redirects.source['old-path'][1], 'new-path')
  assert_eq('route_projection_legacy_alias_unused', query_count(state, '^SELECT %* FROM route_alias$'), 0)
  assert_eq('route_projection_legacy_redirect_unused', query_count(state, '^SELECT %* FROM route_redirect$'), 0)
end

do
  local state = new_projection_state()
  state.route_alias = {
    {source = 'content/2', alias = 'legacy-alias', language = 'all'},
  }

  setup_route_env(state)
  route_aliases_load()

  assert_eq('route_projection_fallback_alias_loaded', ophal.aliases.source['content/2'], 'legacy-alias')
  assert_eq('route_projection_fallback_inserted', state.route_index.alias[1].target, 'legacy-alias')
  assert_eq('route_projection_fallback_version_touched', state.versions.route_alias_index ~= nil, true)
end

io.write '\n-- content projections --\n'

do
  local state = new_projection_state()
  local content

  state.versions.content_public = 200
  state.content_public[5] = {
    id = 5,
    user_id = 1,
    title = 'Projected',
    teaser = 'Projected teaser',
    body = 'Projected body',
    status = 1,
    promote = 1,
    created = 10,
  }

  content = setup_content_env(state)
  local entity = content.load(5)

  assert_eq('content_projection_load_title', entity.title, 'Projected')
  assert_eq('content_projection_load_legacy_unused', query_count(state, '^SELECT %* FROM content WHERE id = %?$'), 0)
end

do
  local state = new_projection_state()
  local content

  state.content_rows[6] = {
    id = 6,
    user_id = 1,
    title = 'Legacy',
    teaser = 'Legacy teaser',
    body = 'Legacy body',
    status = 1,
    promote = 1,
    created = 15,
  }

  local db_query = make_db_query(state)
  local original = db_query
  db_query = function(sql, ...)
    if sql == 'SELECT version FROM projection_version WHERE projection_key = ?' then
      error('no such table: projection_version')
    elseif sql == 'DELETE FROM content_public' then
      error('no such table: content_public')
    elseif sql == 'DELETE FROM content_public WHERE id = ?' then
      error('no such table: content_public')
    elseif sql:match('^INSERT INTO content_public') then
      error('no such table: content_public')
    end
    return original(sql, ...)
  end

  content = setup_content_env(state)
  env.db_query = db_query
  _G.db_query = db_query
  content.init()

  local entity = content.load(6)

  assert_eq('content_projection_fallback_title', entity.title, 'Legacy')
  assert_eq('content_projection_fallback_legacy_used', query_count(state, '^SELECT %* FROM content WHERE id = %?$'), 1)
end

do
  local state = new_projection_state()
  local content

  state.versions.content_public = 300
  state.content_public[7] = {
    id = 7,
    user_id = 1,
    title = 'Front A',
    teaser = 'A',
    body = 'A',
    status = 1,
    promote = 1,
    created = 20,
  }
  state.content_public[8] = {
    id = 8,
    user_id = 2,
    title = 'Front B',
    teaser = 'B',
    body = 'B',
    status = 1,
    promote = 1,
    created = 10,
  }

  content = setup_content_env(state)
  content.frontpage()

  assert_eq('content_projection_frontpage_count_query', query_count(state, '^SELECT count%(%*%) FROM content_public'), 1)
  assert_eq('content_projection_frontpage_rows_query', query_count(state, '^SELECT %* FROM content_public'), 1)
  assert_eq('content_projection_frontpage_legacy_unused', query_count(state, '^SELECT count%(%*%) FROM content WHERE'), 0)
end

io.write(('\n%d passed, %d failed\n'):format(pass_count, fail_count))
if fail_count > 0 then
  os.exit(1)
end
