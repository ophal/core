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

-- Bootstrap loads includes/pager.lua before any module, and the content and tag
-- modules localize `pager_current_page` from it at load time. Load it here for
-- the same reason, so the listing tests below exercise the real clamp rather
-- than a stub. The setups stub `pager` itself; only the clamp is shared.
theme = theme or {}
require 'includes.pager'

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
  local result
  result = {
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
    all = function(self, named)
      local collected = {}

      for row in self:rows(named) do
        collected[#collected + 1] = row
      end

      return collected
    end,
  }
  return result
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
    tag_rows = {},
    field_tag_rows = {},
    tag_listing_index = {},
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
    elseif sql == 'DELETE FROM route_index WHERE kind = ?' then
      state.route_index[args[1]] = {}
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
    elseif sql == 'SELECT * FROM tag WHERE id = ?' then
      row = state.tag_rows[tonumber(args[1])]
      return rows_result(row and {row} or {})
    elseif sql == 'SELECT entity_type FROM field_tag WHERE tag_id = ? GROUP BY entity_type' then
      local seen = {}
      local rows = {}
      for _, item in ipairs(state.field_tag_rows) do
        if tonumber(item.tag_id) == tonumber(args[1]) and not seen[item.entity_type] then
          seen[item.entity_type] = true
          rows[#rows + 1] = {entity_type = item.entity_type}
        end
      end
      return rows_result(rows)
    elseif sql == 'SELECT tag_id id FROM field_tag WHERE entity_type = ? AND entity_id = ?' then
      local rows = {}
      for _, item in ipairs(state.field_tag_rows) do
        if item.entity_type == args[1] and tonumber(item.entity_id) == tonumber(args[2]) then
          rows[#rows + 1] = {id = item.tag_id}
        end
      end
      return rows_result(rows)
    elseif sql == 'DELETE FROM field_tag WHERE entity_type = ? AND entity_id = ? AND tag_id = ?' then
      local kept = {}
      for _, item in ipairs(state.field_tag_rows) do
        if not (item.entity_type == args[1] and tonumber(item.entity_id) == tonumber(args[2]) and tonumber(item.tag_id) == tonumber(args[3])) then
          kept[#kept + 1] = item
        end
      end
      state.field_tag_rows = kept
      return rows_result({})
    elseif sql == 'INSERT INTO field_tag(entity_type, entity_id, tag_id) VALUES(?, ?, ?)' then
      state.field_tag_rows[#state.field_tag_rows + 1] = {
        entity_type = args[1],
        entity_id = tonumber(args[2]),
        tag_id = tonumber(args[3]),
      }
      return rows_result({})
    elseif sql == 'DELETE FROM field_tag WHERE entity_type = ? AND entity_id = ?' then
      local kept = {}
      for _, item in ipairs(state.field_tag_rows) do
        if not (item.entity_type == args[1] and tonumber(item.entity_id) == tonumber(args[2])) then
          kept[#kept + 1] = item
        end
      end
      state.field_tag_rows = kept
      return rows_result({})
    elseif sql == 'DELETE FROM tag_listing_index' then
      state.tag_listing_index = {}
      return rows_result({})
    elseif sql == 'DELETE FROM tag_listing_index WHERE tag_id = ?' then
      local kept = {}
      for _, item in ipairs(state.tag_listing_index) do
        if tonumber(item.tag_id) ~= tonumber(args[1]) then
          kept[#kept + 1] = item
        end
      end
      state.tag_listing_index = kept
      return rows_result({})
    elseif sql:match('^INSERT INTO tag_listing_index') then
      state.tag_listing_index[#state.tag_listing_index + 1] = {
        tag_id = tonumber(args[1]),
        tag_name = args[2],
        entity_type = args[3],
        entity_id = tonumber(args[4]),
        user_id = args[5],
        language = args[6],
        title = args[7],
        teaser = args[8],
        body = args[9],
        created = args[10],
        changed = args[11],
        status = args[12],
        promote = args[13],
        route = args[14],
        updated_at = args[15],
      }
      return rows_result({})
    elseif sql == 'SELECT COUNT(*) FROM tag_listing_index WHERE tag_id = ?' then
      local count = 0
      for _, item in ipairs(state.tag_listing_index) do
        if tonumber(item.tag_id) == tonumber(args[1]) then
          count = count + 1
        end
      end
      return rows_result({{count}})
    elseif sql:match('^SELECT entity_type type, entity_id id, user_id, language, title, teaser, body, created, changed, status, promote, route FROM tag_listing_index') then
      local rows = {}
      for _, item in ipairs(state.tag_listing_index) do
        if tonumber(item.tag_id) == tonumber(args[1]) then
          rows[#rows + 1] = {
            type = item.entity_type,
            id = item.entity_id,
            user_id = item.user_id,
            language = item.language,
            title = item.title,
            teaser = item.teaser,
            body = item.body,
            created = item.created,
            changed = item.changed,
            status = item.status,
            promote = item.promote,
            route = item.route,
          }
        end
      end
      table.sort(rows, function(a, b)
        return (a.created or 0) > (b.created or 0)
      end)
      return rows_result(rows)
    elseif sql:match('^SELECT tag_id id, tag_name name') then
      local seen = {}
      local rows = {}
      for _, item in ipairs(state.tag_listing_index) do
        if not seen[item.tag_id] then
          seen[item.tag_id] = true
          rows[#rows + 1] = {id = item.tag_id, name = item.tag_name}
        end
      end
      table.sort(rows, function(a, b)
        return a.name < b.name
      end)
      return rows_result(rows)
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
    elseif sql:match("^SELECT t%.id tag_id, t%.name tag_name, 'content' entity_type, cp%.id entity_id,") then
      local rows = {}
      for _, rel in ipairs(state.field_tag_rows) do
        local content = state.content_public[tonumber(rel.entity_id)]
        local tag = state.tag_rows[tonumber(rel.tag_id)]
        if rel.entity_type == 'content' and content and tag and content.status == 1 and (args[1] == nil or tonumber(rel.tag_id) == tonumber(args[1])) then
          rows[#rows + 1] = {
            tag_id = rel.tag_id,
            tag_name = tag.name,
            entity_type = 'content',
            entity_id = content.id,
            user_id = content.user_id,
            language = content.language,
            title = content.title,
            teaser = content.teaser,
            body = content.body,
            created = content.created,
            changed = content.changed,
            status = content.status,
            promote = content.promote,
          }
        end
      end
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
    elseif sql:match("^SELECT t%.id tag_id, t%.name tag_name, 'content' entity_type, c%.id entity_id,") then
      local rows = {}
      for _, rel in ipairs(state.field_tag_rows) do
        local content = state.content_rows[tonumber(rel.entity_id)]
        local tag = state.tag_rows[tonumber(rel.tag_id)]
        if rel.entity_type == 'content' and content and tag and content.status == 1 and (args[1] == nil or tonumber(rel.tag_id) == tonumber(args[1])) then
          rows[#rows + 1] = {
            tag_id = rel.tag_id,
            tag_name = tag.name,
            entity_type = 'content',
            entity_id = content.id,
            user_id = content.user_id,
            language = content.language,
            title = content.title,
            teaser = content.teaser,
            body = content.body,
            created = content.created,
            changed = content.changed,
            status = content.status,
            promote = content.promote,
          }
        end
      end
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

local function setup_tag_env(state)
  local user_module = {
    current = function() return {id = 1} end,
    is_logged_in = function() return true end,
    access = function() return true end,
    load = function(id) return {id = id or 0} end,
  }

  settings = {
    tag = {
      entities = {
        content = true,
      },
      items_per_page = 10,
    },
    slash = '/',
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
  header = function(name, value)
    if name == 'status' then
      state.status = value
    end
  end
  pager = function() return {} end
  l = function(text) return text end
  page_set_title = function() end
  add_js = function() end
  theme = setmetatable({}, {__call = function() return '' end})
  request_get_body = function() return '' end
  csrf_validate_request = function() return true end
  csrf_denied = function() end
  print_t = function(variables)
    if variables and variables[1] == 'tag_page' then
      state.rendered_tag_page = variables
    end
  end
  format_date = function(value) return tostring(value) end
  page_not_found = function() return '' end
  -- The tag module localizes `route_arg` at load time, so a test that needs a
  -- different tag id between renders changes `state.route_tag_id` rather than
  -- reassigning the global.
  route_arg = function(index)
    if index == 1 then
      return state.route_tag_id or '1'
    end
  end
  module_invoke_all = function() end
  package.loaded['includes.projection'] = nil
  package.loaded['ophal.modules.tag'] = nil
  dofile('modules/tag/init.lua')
  ophal.modules.tag = package.loaded['ophal.modules.tag'] or ophal.modules.tag
  ophal.modules.tag.init()
  return ophal.modules.tag
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

  assert_eq('core_migration_count', #migrations, 4)
  assert_eq('core_migration_route_index', migrations[1].id, '001_route_index')
  assert_eq('core_migration_content_public', migrations[2].id, '002_content_public')
  assert_eq('core_migration_projection_version', migrations[3].id, '003_projection_version')
  assert_eq('core_migration_tag_listing_index', migrations[4].id, '004_tag_listing_index')
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

do
  local state = new_projection_state()

  state.versions.route_alias_index = 100
  state.versions.route_alias_source = 200
  state.route_index.alias = {
    {source = 'content/old', target = 'stale-alias', language = 'all'},
  }
  state.route_alias = {
    {source = 'content/3', alias = 'fresh-alias', language = 'all'},
  }

  setup_route_env(state)
  route_aliases_load()

  assert_eq('route_projection_stale_rebuilt_alias', ophal.aliases.source['content/3'], 'fresh-alias')
  assert_eq('route_projection_stale_replaced_count', #state.route_index.alias, 1)
  assert_eq('route_projection_stale_removed_old', state.route_index.alias[1].source, 'content/3')
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

-- `current_page` is interpolated into the projection payload cache key, and the
-- payload cache is per-worker and unbounded. Without clamping, each distinct
-- `?page=` value would fill a cache entry that nothing ever evicts, so an
-- anonymous visitor could grow a worker's memory by walking the query string.
-- Clamping collapses every out-of-range value onto a page that exists, which
-- shows up here as a single cache fill instead of one per requested page.
do
  local state = new_projection_state()
  local content

  state.versions.content_public = 300
  state.content_public[11] = {
    id = 11,
    user_id = 1,
    title = 'Only page',
    teaser = 'A',
    body = 'A',
    status = 1,
    promote = 1,
    created = 20,
  }

  content = setup_content_env(state)

  -- One row at 10 per page means page 1 is the only page that exists.
  for _, page in ipairs{'2', '3', '9999', '1e300', '-1', '0', '1.5', 'abc'} do
    _GET.page = page
    content.frontpage()
  end

  assert_eq('frontpage_clamp_single_rows_query', query_count(state, '^SELECT %* FROM content_public'), 1)

  -- The count is cached under a page-independent key, so it stays at one too.
  assert_eq('frontpage_clamp_single_count_query', query_count(state, '^SELECT count%(%*%) FROM content_public'), 1)

  -- The offset handed to SQL is the clamped page, never the raw parameter.
  do
    local offsets = {}
    for _, query in ipairs(state.queries) do
      if query.sql:match('^SELECT %* FROM content_public') then
        offsets[#offsets + 1] = query.params[1]
      end
    end
    assert_eq('frontpage_clamp_offset', offsets[1], 0)
  end
end

do
  local state = new_projection_state()
  local content

  state.versions.content_public = 300
  state.versions.content_source = 400
  state.content_public[9] = {
    id = 9,
    user_id = 1,
    title = 'Stale projected row',
    teaser = 'Stale teaser',
    body = 'Stale body',
    status = 1,
    promote = 1,
    created = 10,
  }
  state.content_rows[9] = {
    id = 9,
    user_id = 1,
    title = 'Fresh legacy row',
    teaser = 'Fresh teaser',
    body = 'Fresh body',
    status = 1,
    promote = 1,
    created = 10,
  }

  content = setup_content_env(state)
  local entity = content.load(9)

  assert_eq('content_projection_stale_rebuilt_title', entity.title, 'Fresh legacy row')
  assert_eq('content_projection_stale_rebuilt_from_source', query_count(state, '^SELECT %* FROM content$'), 1)
end

io.write '\n-- tag projections --\n'

do
  local state = new_projection_state()
  local tag_mod

  state.versions.tag_listing_index = 400
  state.tag_rows[1] = {id = 1, name = 'alpha', description = 'Alpha'}
  state.tag_listing_index = {
    {
      tag_id = 1,
      tag_name = 'alpha',
      entity_type = 'content',
      entity_id = 5,
      user_id = 1,
      title = 'Projected tagged content',
      teaser = 'Projected teaser',
      body = 'Projected body',
      status = 1,
      promote = 1,
      created = 20,
      route = 'content/5',
    },
  }

  tag_mod = setup_tag_env(state)
  tag_mod.entity_page()

  assert_eq('tag_projection_count_query', query_count(state, '^SELECT COUNT%(%*%) FROM tag_listing_index'), 1)
  assert_eq('tag_projection_rows_query', query_count(state, '^SELECT entity_type type, entity_id id, user_id, language, title, teaser, body, created, changed, status, promote, route FROM tag_listing_index'), 1)
  assert_eq('tag_projection_legacy_entity_type_unused', query_count(state, '^SELECT entity_type FROM field_tag'), 0)
end

do
  local state = new_projection_state()
  local tag_mod

  state.tag_rows[1] = {id = 1, name = 'alpha', description = 'Alpha'}
  state.content_public[5] = {
    id = 5,
    user_id = 1,
    title = 'Projected tagged content',
    teaser = 'Projected teaser',
    body = 'Projected body',
    status = 1,
    promote = 1,
    created = 20,
  }
  state.field_tag_rows = {
    {entity_type = 'content', entity_id = 5, tag_id = 1},
  }

  tag_mod = setup_tag_env(state)
  tag_mod.entity_page()

  assert_eq('tag_projection_fallback_rebuild_rows', #state.tag_listing_index, 1)
  assert_eq('tag_projection_fallback_touched', state.versions.tag_listing_index ~= nil, true)
  assert_eq('tag_projection_fallback_title', state.tag_listing_index[1].title, 'Projected tagged content')
end

do
  local state = new_projection_state()
  local tag_mod

  state.versions.tag_listing_index = 500
  state.tag_rows[1] = {id = 1, name = 'alpha'}
  state.tag_rows[2] = {id = 2, name = 'beta'}
  state.content_public[7] = {
    id = 7,
    user_id = 1,
    title = 'Tagged content',
    teaser = 'Tagged teaser',
    body = 'Tagged body',
    status = 1,
    promote = 1,
    created = 30,
  }
  state.field_tag_rows = {
    {entity_type = 'content', entity_id = 7, tag_id = 1},
  }

  tag_mod = setup_tag_env(state)
  tag_mod.entity_after_save({
    type = 'content',
    id = 7,
    tags = {1, 2},
  })

  assert_eq('tag_projection_refresh_row_count', #state.tag_listing_index, 2)
  assert_eq('tag_projection_refresh_has_beta', state.tag_listing_index[2].tag_id, 2)
end

do
  local state = new_projection_state()
  local tag_mod

  state.versions.tag_listing_index = 600
  state.versions.content_public = 700
  state.tag_rows[1] = {id = 1, name = 'alpha'}
  state.content_public[5] = {
    id = 5,
    user_id = 1,
    title = 'Fresh projected tagged content',
    teaser = 'Fresh projected teaser',
    body = 'Fresh projected body',
    status = 1,
    promote = 1,
    created = 40,
  }
  state.field_tag_rows = {
    {entity_type = 'content', entity_id = 5, tag_id = 1},
  }
  state.tag_listing_index = {
    {
      tag_id = 1,
      tag_name = 'alpha',
      entity_type = 'content',
      entity_id = 5,
      user_id = 1,
      title = 'Stale projected tagged content',
      teaser = 'Stale teaser',
      body = 'Stale body',
      status = 1,
      promote = 1,
      created = 5,
      route = 'content/5',
    },
  }

  tag_mod = setup_tag_env(state)
  tag_mod.entity_page()

  assert_eq('tag_projection_stale_rebuilt_title', state.tag_listing_index[1].title, 'Fresh projected tagged content')
  assert_eq('tag_projection_stale_rebuild_source_query', query_count(state, "^SELECT t%.id tag_id, t%.name tag_name, 'content' entity_type, cp%.id entity_id,"), 1)
end

io.write '\n-- tag listing payload cache --\n'

-- Shared fixture for the payload cache tests below: one tag with one projected
-- listing row, and every version already in place so a render starts warm.
local function tag_listing_state()
  local state = new_projection_state()

  state.versions.tag_listing_index = 400
  state.versions.tag_listing_source = 400
  state.versions.content_public = 400
  state.tag_rows[1] = {id = 1, name = 'alpha', description = 'Alpha', user_id = 1}
  state.content_public[5] = {
    id = 5,
    user_id = 1,
    title = 'Projected tagged content',
    teaser = 'Projected teaser',
    body = 'Projected body',
    status = 1,
    promote = 1,
    created = 20,
  }
  state.field_tag_rows = {
    {entity_type = 'content', entity_id = 5, tag_id = 1},
  }
  state.tag_listing_index = {
    {
      tag_id = 1,
      tag_name = 'alpha',
      entity_type = 'content',
      entity_id = 5,
      user_id = 1,
      title = 'Projected tagged content',
      teaser = 'Projected teaser',
      body = 'Projected body',
      status = 1,
      promote = 1,
      created = 20,
      route = 'content/5',
    },
  }

  return state
end

local function render_tag_page(state, tag_mod)
  state.rendered_tag_page = nil
  tag_mod.entity_page()()
  return state.rendered_tag_page
end

do
  local state = tag_listing_state()
  local tag_mod = setup_tag_env(state)
  local first, second

  first = render_tag_page(state, tag_mod)
  assert_eq('tag_listing_cache_first_title', first.rows[1].title, 'Projected tagged content')
  assert_eq('tag_listing_cache_first_links', #first.tag.links, 2)

  -- The warm render must serve the same data, not an empty shell, and it must
  -- serve a copy. The writes below are what a caller does to what it was
  -- handed, and the assertions after them fail if either write reached a cached
  -- entry. The tag entity is the live case: entity_page() builds `links` on it
  -- and the theme closure renders it after the handler returns, so a shared
  -- table lets one request's links reach another request's page.
  first.rows[1].title = 'Mutated by the caller'
  first.tag.name = 'Mutated by the caller'
  second = render_tag_page(state, tag_mod)

  assert_eq('tag_listing_cache_warm_title', second.rows[1].title, 'Projected tagged content')
  assert_eq('tag_listing_cache_warm_name', second.tag.name, 'alpha')
  assert_eq('tag_listing_cache_warm_links', #second.tag.links, 2)
end

do
  local state = tag_listing_state()
  local tag_mod = setup_tag_env(state)
  local renamed

  render_tag_page(state, tag_mod)

  -- A rename is the write the cached tag entity has to survive. It moves the
  -- listing projection version through entity_after_save(), which is the only
  -- reason caching the entity against that version is sound.
  state.tag_rows[1].name = 'renamed'
  tag_mod.entity_after_save({type = 'tag', id = 1})

  renamed = render_tag_page(state, tag_mod)
  assert_eq('tag_listing_cache_rename_visible', renamed.tag.name, 'renamed')
  assert_eq('tag_listing_cache_rename_keeps_rows', #renamed.rows, 1)
end

do
  local state = tag_listing_state()
  local tag_mod = setup_tag_env(state)
  local mark, warm

  render_tag_page(state, tag_mod)

  -- `tag/1.5` is the reason the id is rejected rather than truncated: it stays
  -- the 404 it is today rather than becoming a second URL for tag 1. Both of
  -- these take the uncached load, which is the one query each asserts.
  state.route_tag_id = '1.5'
  state.status = nil
  mark = #state.queries
  tag_mod.entity_page()
  assert_eq('tag_listing_float_id_not_found', state.status, 404)
  assert_eq('tag_listing_float_id_queries', #state.queries - mark, 1)

  state.route_tag_id = 'junk'
  state.status = nil
  mark = #state.queries
  tag_mod.entity_page()
  assert_eq('tag_listing_junk_id_not_found', state.status, 404)
  assert_eq('tag_listing_junk_id_queries', #state.queries - mark, 1)

  -- Neither one may leave anything behind: the real tag still renders, and it
  -- still renders from cache.
  state.route_tag_id = '1'
  mark = #state.queries
  warm = render_tag_page(state, tag_mod)
  assert_eq('tag_listing_real_id_unpoisoned', warm.tag.name, 'alpha')
  assert_eq('tag_listing_real_id_still_cached', #state.queries - mark, 0)
end

do
  local state = tag_listing_state()
  local tag_mod = setup_tag_env(state)
  local menus = {primary_links = {}}
  local first, second, mark

  tag_mod.menus_alter(menus)

  first = menus.tags_menu()
  -- Counted by shape rather than by total: the first call is also the one that
  -- warms the version caches through tag_projection_ready().
  assert_eq('tag_menu_first_queries', query_count(state, '^SELECT tag_id id, tag_name name'), 1)
  assert_eq('tag_menu_first_label', first['tag/1'][1], 'alpha')

  -- The menu renders on every page, so it is the projection's most frequent
  -- read. What is cached is the row set: each call still gets its own `items`
  -- table, because the menu system writes to what it is handed.
  first['tag/1'][1] = 'Mutated by the caller'
  mark = #state.queries
  second = menus.tags_menu()

  assert_eq('tag_menu_warm_queries', #state.queries - mark, 0)
  assert_eq('tag_menu_warm_label', second['tag/1'][1], 'alpha')
  assert_eq('tag_menu_warm_fresh_table', second ~= first, true)
end

io.write '\n-- projection version cache --\n'

local function new_shared_dict()
  local store = {}

  return {
    get = function(_, key) return store[key] end,
    set = function(_, key, value) store[key] = value return true end,
    store = store,
  }
end

local function setup_projection_env(state, shared)
  settings = {}
  db_query = make_db_query(state)
  if shared then
    ngx = {shared = {ophal_projection_versions = shared}}
  else
    ngx = nil
  end
  package.loaded['includes.projection'] = nil
  return require 'includes.projection'
end

local VERSION_SQL = '^SELECT version FROM projection_version WHERE projection_key = %?$'

-- Per-worker cache must answer without re-querying SQL. The pre-fix code ran
-- the SELECT unconditionally, so the cache removed no database work at all.
do
  local state = new_projection_state()
  local projection

  state.versions.content_public = 200
  projection = setup_projection_env(state)

  assert_eq('version_cache_first_read', projection.version('content_public'), 200)
  assert_eq('version_cache_second_read', projection.version('content_public'), 200)
  assert_eq('version_cache_single_sql', query_count(state, VERSION_SQL), 1)
end

-- A version already published to the shared dict is served without SQL.
do
  local state = new_projection_state()
  local shared = new_shared_dict()
  local projection

  state.versions.content_public = 200
  shared.store.content_public = 500
  projection = setup_projection_env(state, shared)

  assert_eq('version_shared_hit_value', projection.version('content_public'), 500)
  assert_eq('version_shared_hit_no_sql', query_count(state, VERSION_SQL), 0)
end

-- touch() must publish the new version so other workers observe the write.
do
  local state = new_projection_state()
  local shared = new_shared_dict()
  local projection = setup_projection_env(state, shared)

  projection.touch('content_public', 900)

  assert_eq('version_touch_publishes_shared', shared.store.content_public, 900)
  assert_eq('version_touch_persists_sql', state.versions.content_public, 900)
end

-- Cross-worker invalidation: this worker caches a payload at version 1, another
-- worker bumps the shared version, and the stale payload must not be reused.
do
  local state = new_projection_state()
  local shared = new_shared_dict()
  local projection
  local loads = 0
  local function loader()
    loads = loads + 1
    return {title = ('load %d'):format(loads)}
  end
  local first, second, third

  shared.store.content_public = 1
  projection = setup_projection_env(state, shared)

  first = projection.cached_value('content_public', 'entity:1', loader)
  second = projection.cached_value('content_public', 'entity:1', loader)

  assert_eq('payload_cache_first_value', first.title, 'load 1')
  assert_eq('payload_cache_reused_value', second.title, 'load 1')
  assert_eq('payload_cache_single_load', loads, 1)

  -- Another worker writes and bumps the shared version.
  shared.store.content_public = 2

  third = projection.cached_value('content_public', 'entity:1', loader)

  assert_eq('payload_cache_invalidated_value', third.title, 'load 2')
  assert_eq('payload_cache_reloaded_once', loads, 2)
end

-- The payload cache is per-worker and is only dropped by a version change or
-- cache_clear_all(), so it needs a size bound of its own. Without one a worker
-- keeps every payload it ever loaded for as long as the version holds still.
local function counting_loader()
  local loads = {}

  return loads, function(key)
    return function()
      loads[key] = (loads[key] or 0) + 1
      return {key = key}
    end
  end
end

do
  local state = new_projection_state()
  local projection
  local loads, loader_for = counting_loader()

  state.versions.content_public = 400
  projection = setup_projection_env(state)
  settings.performance = {projection_payload_cache_size = 3}

  for i = 1, 5 do
    local key = ('entity:%d'):format(i)
    projection.cached_value('content_public', key, loader_for(key))
  end

  -- The three most recent keys stay resident.
  for i = 3, 5 do
    local key = ('entity:%d'):format(i)
    projection.cached_value('content_public', key, loader_for(key))
    assert_eq('payload_cache_bound_keeps_' .. i, loads[key], 1)
  end

  -- The two oldest were evicted, so they have to load again.
  projection.cached_value('content_public', 'entity:1', loader_for('entity:1'))
  assert_eq('payload_cache_bound_evicts_oldest', loads['entity:1'], 2)
end

-- Eviction order must be least-recently-used, not oldest-inserted. A key that
-- keeps getting hit is exactly the one worth keeping.
do
  local state = new_projection_state()
  local projection
  local loads, loader_for = counting_loader()

  state.versions.content_public = 400
  projection = setup_projection_env(state)
  settings.performance = {projection_payload_cache_size = 2}

  projection.cached_value('content_public', 'a', loader_for('a'))
  projection.cached_value('content_public', 'b', loader_for('b'))

  -- Touching 'a' makes 'b' the least recently used entry.
  projection.cached_value('content_public', 'a', loader_for('a'))
  projection.cached_value('content_public', 'c', loader_for('c'))

  projection.cached_value('content_public', 'a', loader_for('a'))
  assert_eq('payload_cache_lru_keeps_recently_used', loads.a, 1)

  projection.cached_value('content_public', 'b', loader_for('b'))
  assert_eq('payload_cache_lru_evicts_least_used', loads.b, 2)
end

-- A fractional or unusable size must not leave the cache unbounded.
do
  local state = new_projection_state()
  local projection
  local loads, loader_for = counting_loader()

  state.versions.content_public = 400
  projection = setup_projection_env(state)
  settings.performance = {projection_payload_cache_size = 2.9}

  for _, key in ipairs{'a', 'b', 'c'} do
    projection.cached_value('content_public', key, loader_for(key))
  end

  projection.cached_value('content_public', 'a', loader_for('a'))
  assert_eq('payload_cache_size_floors', loads.a, 2)

  -- A nonsense value falls back to the default rather than to no bound.
  settings.performance = {projection_payload_cache_size = 'plenty'}
  projection.cached_value('content_public', 'z', loader_for('z'))
  projection.cached_value('content_public', 'z', loader_for('z'))
  assert_eq('payload_cache_size_invalid_defaults', loads.z, 1)
end

-- A size of 0 turns payload caching off, which is the operational escape hatch
-- for debugging a suspected stale payload.
do
  local state = new_projection_state()
  local projection
  local loads, loader_for = counting_loader()

  state.versions.content_public = 400
  projection = setup_projection_env(state)

  projection.cached_value('content_public', 'a', loader_for('a'))
  settings.performance = {projection_payload_cache_size = 0}

  projection.cached_value('content_public', 'a', loader_for('a'))
  projection.cached_value('content_public', 'a', loader_for('a'))
  assert_eq('payload_cache_disabled_always_loads', loads.a, 3)

  -- Turning it back on must not resurrect what was cached before.
  settings.performance = {projection_payload_cache_size = 8}
  projection.cached_value('content_public', 'a', loader_for('a'))
  assert_eq('payload_cache_disabled_drops_bucket', loads.a, 4)
end

-- A projection with no version row must not re-query on every call. Storing a
-- nil in the L1 table is indistinguishable from storing nothing, so before the
-- miss cache this put one `projection_version` SELECT on every anonymous page
-- for any source key nothing had touched yet.
do
  local state = new_projection_state()
  local projection = setup_projection_env(state)

  assert_eq('version_miss_first_read', projection.version('content_source'), nil)
  assert_eq('version_miss_second_read', projection.version('content_source'), nil)
  assert_eq('version_miss_single_sql', query_count(state, VERSION_SQL), 1)
end

-- The same hole existed on the shared-zone path, which is the one production
-- runs: an absent zone entry fell straight through to SQL.
do
  local state = new_projection_state()
  local shared = new_shared_dict()
  local projection = setup_projection_env(state, shared)

  projection.version('content_source')
  projection.version('content_source')

  assert_eq('version_miss_shared_single_sql', query_count(state, VERSION_SQL), 1)
end

-- A miss must not be remembered past its TTL, because a version row can appear
-- from a CLI or cron process that has no shared zone to publish into.
do
  local state = new_projection_state()
  local projection

  settings = {}
  projection = setup_projection_env(state)
  settings.performance = {projection_version_miss_ttl = 0}

  projection.version('content_source')
  projection.version('content_source')

  assert_eq('version_miss_ttl_zero_requeries', query_count(state, VERSION_SQL), 2)
end

-- touch() publishes a version, which must retire the remembered miss rather
-- than leave the worker serving nil until the TTL lapses.
do
  local state = new_projection_state()
  local projection = setup_projection_env(state)

  projection.version('content_source')
  projection.touch('content_source', 700)

  assert_eq('version_miss_cleared_by_touch', projection.version('content_source'), 700)
end

-- projection_cache_clear() must drop both tiers of per-worker state.
do
  local state = new_projection_state()
  local projection

  state.versions.content_public = 200
  projection = setup_projection_env(state)

  projection.version('content_public')
  projection_cache_clear()
  projection.version('content_public')

  assert_eq('version_cache_clear_requeries', query_count(state, VERSION_SQL), 2)
end

io.write '\n-- anonymous SQL budget --\n'

-- Phase 4 exits when normal anonymous delivery stops reading normalized
-- tables. The assertions above name one query shape at a time, which only
-- proves that the fallbacks someone already thought of are gone. These walk
-- every query a warm read still issues and fail on any table that is not a
-- projection, so a newly introduced fallback surfaces without anyone having
-- predicted it. The classifier is the one `db_query()` uses in production, so
-- the budget measured here is the budget a real worker reports.
local db_stats = require 'includes.database.stats'

local function first_normalized_since(state, mark)
  for index = mark + 1, #state.queries do
    local sql = state.queries[index].sql

    for _, name in ipairs(db_stats.tables(sql)) do
      if not db_stats.is_projection_table(name) then
        return ('%s in %q'):format(name, sql)
      end
    end
  end

  return 'none'
end

local function queries_since(state, mark)
  return #state.queries - mark
end

-- Front page: the second anonymous hit is served entirely from the payload
-- cache, so it reaches neither normalized tables nor SQL at all.
do
  local state = new_projection_state()
  local content
  local mark

  state.versions.content_public = 300
  state.content_public[21] = {
    id = 21,
    user_id = 1,
    title = 'Front A',
    teaser = 'A',
    body = 'A',
    status = 1,
    promote = 1,
    created = 20,
  }

  content = setup_content_env(state)
  content.frontpage()
  mark = #state.queries
  content.frontpage()

  assert_eq('budget_frontpage_no_normalized', first_normalized_since(state, mark), 'none')
  assert_eq('budget_frontpage_warm_queries', queries_since(state, mark), 0)
end

-- Content page: same claim for a single entity read.
do
  local state = new_projection_state()
  local content
  local mark

  state.versions.content_public = 300
  state.content_public[22] = {
    id = 22,
    user_id = 1,
    title = 'Projected',
    teaser = 'T',
    body = 'B',
    status = 1,
    promote = 1,
    created = 20,
  }

  content = setup_content_env(state)
  content.load(22)
  mark = #state.queries
  content.load(22)

  assert_eq('budget_content_load_no_normalized', first_normalized_since(state, mark), 'none')
  assert_eq('budget_content_load_warm_queries', queries_since(state, mark), 0)
end

-- Route resolution: the alias and redirect indexes are held in worker memory
-- and only resync when the projection version moves, so a repeat request
-- resolves without touching `route_alias` or `route_redirect`.
do
  local state = new_projection_state()
  local mark

  state.versions.route_alias_index = 100
  state.versions.route_redirect_index = 100
  state.route_index.alias = {
    {kind = 'alias', source = 'content/21', target = 'front-a', language = 'en'},
  }

  setup_route_env(state)
  route_aliases_load()
  route_redirects_load()
  route_redirect()
  mark = #state.queries
  route_redirect()

  assert_eq('budget_route_no_normalized', first_normalized_since(state, mark), 'none')
  assert_eq('budget_route_warm_queries', queries_since(state, mark), 0)
end

-- Tag listing: reads are projection-backed, so the budget holds, but the
-- payload cache does not cover them yet. The warm request still issues the
-- count and rows queries against `tag_listing_index`, which is the measurement
-- behind the remaining Phase 4 item rather than a defect in this test.
do
  local state = new_projection_state()
  local tag_mod
  local mark

  state.versions.tag_listing_index = 400
  state.tag_rows[1] = {id = 1, name = 'alpha', description = 'Alpha'}
  state.tag_listing_index = {
    {
      tag_id = 1,
      tag_name = 'alpha',
      entity_type = 'content',
      entity_id = 5,
      user_id = 1,
      title = 'Projected tagged content',
      teaser = 'Projected teaser',
      body = 'Projected body',
      status = 1,
      promote = 1,
      created = 20,
      route = 'content/5',
    },
  }

  tag_mod = setup_tag_env(state)
  tag_mod.entity_page()
  mark = #state.queries
  tag_mod.entity_page()

  -- The tag entity, the listing count, and the listing rows all come from the
  -- payload cache now, so a warm listing is the same shape as a warm front
  -- page: no normalized read, and no query at all.
  assert_eq('budget_tag_listing_no_normalized', first_normalized_since(state, mark), 'none')
  assert_eq('budget_tag_listing_warm_queries', queries_since(state, mark), 0)
end

ngx = nil

io.write(('\n%d passed, %d failed\n'):format(pass_count, fail_count))
if fail_count > 0 then
  os.exit(1)
end
