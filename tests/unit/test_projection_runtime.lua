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
    -- Tagged entity types other than `content`, keyed by type then by id. The
    -- legacy listing unions one arm per type, and a tag on two of them is the
    -- case that path had never run.
    entity_rows = {},
    jobs = {},
  }
end

--[[ The rows one legacy listing arm would return.

  `content` keeps its own table in the state because every other case uses it;
  anything else comes from `state.entity_rows`, which is how a second tagged
  entity type is seeded. Each row carries its `type`, the way the arm's literal
  first column does.
]]
local function legacy_tagged_rows(state, entity_type, tag_id)
  local source = entity_type == 'content'
    and state.content_rows
    or (state.entity_rows or {})[entity_type] or {}
  local rows = {}

  for _, rel in ipairs(state.field_tag_rows) do
    local row = source[tonumber(rel.entity_id)]

    if rel.entity_type == entity_type and row and row.status == 1
        and tonumber(rel.tag_id) == tonumber(tag_id) then
      local copy = {type = entity_type}

      for key, value in pairs(row) do
        copy[key] = value
      end

      rows[#rows + 1] = copy
    end
  end

  return rows
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

    -- `state.fail_query` is a pattern; a matching statement raises the way the
    -- driver does when its table is gone. The attempt is recorded first, so a
    -- test can still see that it was made.
    if state.fail_query and sql:match(state.fail_query) then
      error(state.fail_error or 'no such table: tag_listing_index')
    end

    if sql:match('^INSERT INTO ophal_jobs') then
      -- `ON CONFLICT(active_key) DO NOTHING`. A deferred rebuild is queued once
      -- however many requests notice it, which is the only reason deferral is
      -- cheaper than rebuilding: without the dedup every request in the stale
      -- window would queue another copy of the same work.
      local active_key = args[3]

      if state.jobs_absent then
        error('no such table: ophal_jobs')
      end

      if active_key ~= nil then
        for _, job in ipairs(state.jobs) do
          if job.active_key == active_key then
            return rows_result({})
          end
        end
      end

      state.jobs[#state.jobs + 1] = {
        kind = args[1],
        dedup_key = args[2],
        active_key = active_key,
        created_at = args[8],
      }
      return rows_result({})
    elseif sql == 'SELECT created_at FROM ophal_jobs WHERE active_key = ?' then
      -- `active_key` is nulled when a job finishes, so a row answering here is
      -- a live one by construction, and the unique index means there is at most
      -- one. A test seeds `state.jobs` with an old `created_at` to stand for a
      -- queue that nothing has drained.
      if state.jobs_absent then
        error('no such table: ophal_jobs')
      end

      for _, job in ipairs(state.jobs) do
        if job.active_key == args[1] then
          return rows_result({{created_at = job.created_at}})
        end
      end

      return rows_result({})
    elseif sql == 'SELECT version FROM projection_version WHERE projection_key = ?' then
      row = state.versions[args[1]]
      if row == nil then
        return rows_result({})
      end
      return rows_result({{version = row}})
    elseif sql:match('^INSERT INTO projection_version%\(') then
      -- One upsert, matched by prefix because the statement spans lines. It
      -- replaced a DELETE and an INSERT; a touch that starts issuing two
      -- queries again shows up in the budget assertions below.
      state.versions[args[1]] = args[2]
      return rows_result({})
    elseif sql == 'SELECT * FROM route_index WHERE kind = ?' then
      -- One statement for both kinds now: `kind` was a literal in the reads and
      -- a bind parameter in the writes, so the same projection was addressed
      -- two ways.
      return rows_result(state.route_index[args[1]] or {})
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
    elseif sql == 'SELECT t.* FROM field_tag ft JOIN tag t ON t.id = ft.tag_id WHERE ft.entity_type = ? AND ft.entity_id = ?' then
      local rows = {}
      for _, item in ipairs(state.field_tag_rows) do
        if item.entity_type == args[1] and tonumber(item.entity_id) == tonumber(args[2]) then
          local tag = state.tag_rows[tonumber(item.tag_id)]
          if tag then
            rows[#rows + 1] = {id = tag.id, name = tag.name}
          end
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
    elseif sql == 'SELECT COUNT(*) AS total FROM tag_listing_index WHERE tag_id = ?' then
      local count = 0
      for _, item in ipairs(state.tag_listing_index) do
        if tonumber(item.tag_id) == tonumber(args[1]) then
          count = count + 1
        end
      end
      return rows_result({{total = count}})
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
    elseif sql:match('^SELECT count%(%*%) AS total FROM content_public') then
      local count = 0
      for _, item in pairs(state.content_public) do
        if item.promote == 1 and (sql:find('AND status = 1', 1, true) == nil or item.status == 1) then
          count = count + 1
        end
      end
      return rows_result({{total = count}})
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
    elseif sql:match('^SELECT SUM%(total%) AS total FROM %(') then
      --[[ The tag listing's legacy count: one `SELECT COUNT(*)` arm per tagged
        entity type, summed over the arms. Deferral made this path ordinary
        traffic rather than a missing-table fallback, so the fake answers it --
        and it answers it per arm, because reading only the first row is the
        defect the sum replaced.
      ]]
      local count, arm = 0, 0
      for entity_type in sql:gmatch('FROM ([%w_]+) e JOIN field_tag ft') do
        arm = arm + 1
        count = count + #legacy_tagged_rows(state, entity_type, args[arm])
      end
      return rows_result({{total = count}})
    elseif sql:match("^SELECT '[%w_]+' type, e%.id id,") then
      -- The rows the count above counted, in the same arm order. Each arm binds
      -- its own `ft.tag_id = ?`, so the parameters run one per arm and the
      -- paging pair comes after them.
      local rows, arm = {}, 0
      for entity_type in sql:gmatch('FROM ([%w_]+) e JOIN field_tag ft') do
        arm = arm + 1
        for _, row in ipairs(legacy_tagged_rows(state, entity_type, args[arm])) do
          rows[#rows + 1] = row
        end
      end
      table.sort(rows, function(a, b)
        return (a.created or 0) > (b.created or 0)
      end)
      -- The paging pair follows the arms, so the fake has to page: whether a
      -- listing's count and its rows agree is exactly what the multi-arm case
      -- is here to check.
      do
        local offset = tonumber(args[arm + 1]) or 0
        local limit = tonumber(args[arm + 2]) or #rows
        local page = {}

        for i = offset + 1, math.min(offset + limit, #rows) do
          page[#page + 1] = rows[i]
        end

        rows = page
      end
      return rows_result(rows)
    elseif sql:match('^SELECT count%(%*%) AS total FROM content WHERE') then
      local count = 0
      for _, item in pairs(state.content_rows) do
        if item.promote == 1 and (sql:find('AND status = 1', 1, true) == nil or item.status == 1) then
          count = count + 1
        end
      end
      return rows_result({{total = count}})
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

--[[ One stub, installed as both shapes.

  `db_query` is the transitional free function and `db_connection()` the
  accessor; they must be the same fake, or a test measuring queries would count
  only half of them. `tests/unit/db_fake.lua` resolves a statement name through
  the real registry and hands the body to the dispatcher below, so a statement
  that is renamed or rewritten either still matches this stand-in or the test
  says so.
]]
local db_fake = require 'tests.unit.db_fake'

local function install_db(state, ...)
  local query = make_db_query(state)

  db_fake.install({sql = query}, ...)

  return query
end


-- `entities` overrides the tag module's configured entity types. The default is
-- the one shape `tag_projection_supported()` accepts; a test that needs the
-- unsupported shape passes its own.
local function setup_tag_env(state, entities)
  local user_module = {
    current = function() return {id = 1} end,
    is_logged_in = function() return true end,
    access = function() return true end,
    load = function(id) return {id = id or 0} end,
  }

  settings = {
    tag = {
      entities = entities or {
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
    db_limit = function() return ' LIMIT ?, ?' end,
    db_last_insert_id = function() return 1 end,
  }
  install_db(state, env, _G)
  _GET = {}
  header = function(name, value)
    if name == 'status' then
      state.status = value
    end
  end
  pager = function(_, pages, current)
    state.pager = {pages = pages, current = current}
    return {}
  end
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

-- The projection keys a run has queued a rebuild for, in order.
local function queued_rebuilds(state)
  local keys = {}

  for _, job in ipairs(state.jobs) do
    keys[#keys + 1] = tostring(job.dedup_key)
  end

  return table.concat(keys, ',')
end

-- Stands in for the cron drain. The queue round trip is covered in
-- `test_jobs.lua` and end to end in the smoke suite; what these tests are about
-- is that the request queued the work and served correct content without doing
-- it, and that running it afterwards puts the projection back.
local function run_queued_rebuild(key)
  return require('includes.projection').run_rebuild(key)
end

--[[ How many recorded statements match.

  `first_param` narrows a statement that serves several cases through one bind
  parameter -- the route index is read with `kind = ?` rather than once per kind
  -- so counting the alias reads still means counting alias reads.
]]
local function query_count(state, pattern, first_param)
  local count = 0
  for _, query in ipairs(state.queries) do
    if query.sql:match(pattern)
        and (first_param == nil or query.params[1] == first_param) then
      count = count + 1
    end
  end
  return count
end

-- `projection_overrides` replaces functions on the projection module before
-- `includes/route.lua` captures them as upvalues, which is the only way to make
-- `ensure` answer something the current code cannot yet produce.
local function setup_route_env(state, projection_overrides)
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
  install_db(state, _G)
  db_last_insert_id = function() return 1 end
  module_invoke_all = function() end
  request_path = function() return '' end
  go_to = function() end
  package.loaded['includes.projection'] = nil

  if projection_overrides then
    local projection = require 'includes.projection'

    for name, replacement in pairs(projection_overrides) do
      projection[name] = replacement
    end
  end

  dofile('includes/route.lua')
end

local function setup_content_env(state, projection_overrides)
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
    db_limit = function() return ' LIMIT ?, ?' end,
    db_last_insert_id = function() return 1 end,
  }
  install_db(state, env, _G)
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

  -- Same trick as `setup_route_env()`: the module captures the projection
  -- functions as upvalues at load time, so an override has to be in place
  -- before the file is read.
  if projection_overrides then
    local projection = require 'includes.projection'

    for name, replacement in pairs(projection_overrides) do
      projection[name] = replacement
    end
  end

  dofile('modules/content/init.lua')
  ophal.modules.content = package.loaded['ophal.modules.content'] or ophal.modules.content
  ophal.modules.content.init()
  return ophal.modules.content
end

io.write '\n-- flag columns are integers --\n'

--[[ A Lua boolean must never reach a flag column.

  Every flag in the schema is `smallint` on PostgreSQL and `BOOLEAN` -- which is
  an integer -- on SQLite. PostgreSQL type-checks a bound parameter instead of
  coercing it, so `promote` defaulting to `false` is
  `column "promote" is of type smallint but expression is of type boolean`, on
  the create path, for any article saved without the checkbox. SQLite and MySQL
  both take it, which is why four call sites carried the defect until stage
  8.7's PostgreSQL profile ran the authoring path on a third backend --
  `modules/content`, `modules/comment`, `modules/user` and `modules/file`.

  Content is the one with a unit harness, so it is the one pinned here; the
  other three are covered by that profile, which is the argument for it running
  on every build rather than when someone remembers to.
]]
do
  local state = new_projection_state()
  local content = setup_content_env(state)
  local insert

  content.create{
    user_id = 1,
    title = 'Unpromoted',
    teaser = 'teaser',
    body = 'body',
    status = 1,
    created = 10,
  }

  for _, query in ipairs(state.queries) do
    if query.sql:match('^INSERT INTO content%\(') then
      insert = query
      break
    end
  end

  assert_eq('content_create_issued_an_insert', insert ~= nil, true)
  -- The declaration's order is user_id, title, teaser, body, status, promote,
  -- created, so the sixth parameter is the one that defaulted.
  assert_eq('content_create_promote_is_a_number',
    type((insert or {params = {}}).params[6]), 'number')
  assert_eq('content_create_promote_defaults_to_zero',
    (insert or {params = {}}).params[6], 0)
end

io.write '\n-- core migrations registry --\n'

do
  local migrations = dofile('includes/migrations.lua')

  assert_eq('core_migration_count', #migrations, 5)
  assert_eq('core_migration_route_index', migrations[1].id, '001_route_index')
  assert_eq('core_migration_content_public', migrations[2].id, '002_content_public')
  assert_eq('core_migration_projection_version', migrations[3].id, '003_projection_version')
  assert_eq('core_migration_tag_listing_index', migrations[4].id, '004_tag_listing_index')
  assert_eq('core_migration_jobs', migrations[5].id, '005_jobs')
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

-- A projection that has never been built is not rebuilt from inside the request
-- that noticed. The request registers its aliases from the normalized source --
-- correct, and one query -- and queues the rebuild for the runner. This is the
-- whole point of the phase, and routes are where it matters most: the alias
-- table is loaded in bootstrap, before routing, on every single request.
do
  local state = new_projection_state()
  state.route_alias = {
    {source = 'content/2', alias = 'legacy-alias', language = 'all'},
  }

  setup_route_env(state)
  route_aliases_load()

  assert_eq('route_deferred_fallback_alias_loaded', ophal.aliases.source['content/2'], 'legacy-alias')
  assert_eq('route_deferred_fallback_queued', queued_rebuilds(state), 'route_alias_index')
  assert_eq('route_deferred_fallback_wrote_nothing', #state.route_index.alias, 0)
  assert_eq('route_deferred_fallback_version_unmoved', state.versions.route_alias_index, nil)

  -- A second request in the same window queues nothing more and still serves
  -- the right answer. Without the dedup, a stale window costs one job per
  -- request.
  route_aliases_load()
  assert_eq('route_deferred_queued_once', queued_rebuilds(state), 'route_alias_index')

  -- And the runner puts it back.
  run_queued_rebuild('route_alias_index')
  assert_eq('route_deferred_rebuild_inserted', state.route_index.alias[1].target, 'legacy-alias')
  assert_eq('route_deferred_rebuild_version_touched', state.versions.route_alias_index ~= nil, true)

  -- Once rebuilt, the next request reads the index and never touches the
  -- normalized table again.
  local before = query_count(state, '^SELECT %* FROM route_alias$')
  route_aliases_load()
  assert_eq(
    'route_deferred_rebuilt_serves_from_index',
    query_count(state, '^SELECT %* FROM route_alias$'),
    before
  )
  assert_eq('route_deferred_rebuilt_alias', ophal.aliases.source['content/2'], 'legacy-alias')
end

-- An unmigrated site has no queue to defer into, so it rebuilds inline exactly
-- as it always did. Nothing in this phase changes behavior before `005_jobs`.
do
  local state = new_projection_state()
  state.jobs_absent = true
  state.route_alias = {
    {source = 'content/4', alias = 'unmigrated-alias', language = 'all'},
  }

  setup_route_env(state)
  route_aliases_load()

  assert_eq('route_unmigrated_rebuilds_inline', state.route_index.alias[1].target, 'unmigrated-alias')
  assert_eq('route_unmigrated_queued_nothing', queued_rebuilds(state), '')
  assert_eq('route_unmigrated_version_touched', state.versions.route_alias_index ~= nil, true)
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

  -- The stale index is not read and not repaired: the request registers the
  -- fresh aliases from the source and queues the rebuild. Serving from an index
  -- known to be behind is the bug this replaces; rebuilding it here is the
  -- latency this phase exists to remove.
  assert_eq('route_stale_serves_fresh_alias', ophal.aliases.source['content/3'], 'fresh-alias')
  assert_eq('route_stale_old_alias_gone', ophal.aliases.source['content/old'], nil)
  assert_eq('route_stale_queued', queued_rebuilds(state), 'route_alias_index')
  assert_eq('route_stale_index_untouched', #state.route_index.alias, 1)
  assert_eq('route_stale_version_unmoved', state.versions.route_alias_index, 100)

  run_queued_rebuild('route_alias_index')

  assert_eq('route_stale_rebuilt_replaced_count', #state.route_index.alias, 1)
  assert_eq('route_stale_rebuilt_removed_old', state.route_index.alias[1].source, 'content/3')
end

-- A rebuild is `N + 4` statements, not `3N + 4`. The per-source DELETE and the
-- per-row version touch were both redundant: the clear at the top has already
-- removed every row of this kind, and the touch at the end writes the same
-- value the N touches before it wrote. It matters because this rebuild runs
-- from bootstrap, before routing, on a table whose size is the number of
-- aliases on the site.
do
  local state = new_projection_state()

  state.route_alias = {
    {source = 'content/1', alias = 'a-1', language = 'all'},
    {source = 'content/2', alias = 'a-2', language = 'all'},
    {source = 'content/3', alias = 'a-3', language = 'all'},
  }

  setup_route_env(state)
  route_aliases_load()
  run_queued_rebuild('route_alias_index')

  assert_eq(
    'route_rebuild_clears_kind_once',
    query_count(state, '^DELETE FROM route_index WHERE kind = %?$'),
    1
  )
  assert_eq(
    'route_rebuild_skips_per_source_delete',
    query_count(state, '^DELETE FROM route_index WHERE kind = %? AND source = %?$'),
    0
  )
  assert_eq(
    'route_rebuild_inserts_each_row',
    query_count(state, '^INSERT INTO route_index'),
    3
  )
  -- Two touches for three rows: the index key and the source key, once each.
  assert_eq(
    'route_rebuild_touches_each_version_once',
    query_count(state, '^INSERT INTO projection_version%\('),
    2
  )
  assert_eq('route_rebuild_registered_all', ophal.aliases.source['content/3'], 'a-3')
end

-- What happens when `ensure` declines to rebuild. Nothing produces that answer
-- yet, so it is forced here: the point of splitting the loader from the writer
-- is that this branch reads the source and writes nothing, and the branch is
-- worth pinning before anything depends on it. Calling the rebuild here instead
-- -- which is what the code did -- would make deferral a no-op on the one
-- projection that loads before routing on every request.
do
  local state = new_projection_state()

  state.route_alias = {
    {source = 'content/9', alias = 'deferred-alias', language = 'all'},
  }

  setup_route_env(state, {ensure = function() return false end})
  route_aliases_load()

  assert_eq('route_deferred_serves_from_source', ophal.aliases.source['content/9'], 'deferred-alias')
  assert_eq('route_deferred_writes_no_rows', #state.route_index.alias, 0)
  assert_eq(
    'route_deferred_writes_no_versions',
    query_count(state, '^INSERT INTO projection_version%\('),
    0
  )
  assert_eq(
    'route_deferred_does_not_clear',
    query_count(state, '^DELETE FROM route_index'),
    0
  )
end

do
  local state = new_projection_state()

  state.route_redirect = {
    {source = 'old', target = 'new', language = 'all', type = 301},
  }

  setup_route_env(state, {ensure = function() return false end})
  route_redirects_load()

  assert_eq('route_deferred_redirect_from_source', ophal.redirects.source['old'][1], 'new')
  assert_eq('route_deferred_redirect_writes_no_rows', #state.route_index.redirect, 0)
end

io.write '\n-- reusing a loaded route table --\n'

local ALIAS_INDEX_READ = '^SELECT %* FROM route_index WHERE kind = %?$'
local ALIAS_SOURCE_READ = '^SELECT %* FROM route_alias$'

-- Bootstrap loads the alias table before routing on every request, and nothing
-- between requests clears it, so re-reading it is repetition unless a version
-- moved. This was the one query a warm anonymous request paid that was not a
-- connection pragma, and it carried a row per alias on the site with it.
do
  local state = new_projection_state()
  local projection
  local before

  state.versions.route_alias_index = 100
  state.versions.route_alias_source = 90
  state.route_index.alias = {
    {source = 'content/1', target = 'hello-world', language = 'all'},
  }

  setup_route_env(state)
  projection = require 'includes.projection'
  route_aliases_load()

  before = query_count(state, ALIAS_INDEX_READ, 'alias')
  assert_eq('route_reload_first_load_reads_index', before, 1)

  route_aliases_load()

  assert_eq('route_reload_skipped_when_unchanged', query_count(state, ALIAS_INDEX_READ, 'alias'), before)
  assert_eq('route_reload_keeps_aliases', ophal.aliases.source['content/1'], 'hello-world')

  -- The index version moving is a rebuild or a single-row projection write.
  projection.touch('route_alias_index', 300)
  state.route_index.alias = {
    {source = 'content/1', target = 'renamed', language = 'all'},
  }
  route_aliases_load()

  assert_eq('route_reload_on_index_version_move', ophal.aliases.source['content/1'], 'renamed')

  -- The source version moving on its own is the deferred window: incremental
  -- index maintenance is suspended there, so the index version is the half that
  -- stays put. It is still behind the index here, so the projection reads as
  -- fresh and this reload is the source comparison alone.
  projection.touch('route_alias_source', 250)
  state.route_index.alias = {
    {source = 'content/1', target = 'renamed-again', language = 'all'},
  }
  route_aliases_load()

  assert_eq('route_reload_on_source_version_move', ophal.aliases.source['content/1'], 'renamed-again')
end

-- A version stamped during the second the load is running cannot be told apart
-- from one stamped just before it, so that load is never reused. The clock is
-- frozen here because that is the whole assertion: a real one ticks past the
-- ambiguity and hides it.
do
  local state = new_projection_state()
  local real_time = os.time
  local frozen = real_time()
  local before

  os.time = function() return frozen end

  state.versions.route_alias_index = frozen
  state.versions.route_alias_source = frozen - 10
  state.route_index.alias = {
    {source = 'content/1', target = 'same-second', language = 'all'},
  }

  setup_route_env(state)
  route_aliases_load()

  before = query_count(state, ALIAS_INDEX_READ, 'alias')
  route_aliases_load()

  assert_eq(
    'route_same_second_load_not_reused',
    query_count(state, ALIAS_INDEX_READ, 'alias'),
    before + 1
  )

  os.time = real_time
end

-- A table built from the normalized fallback is reusable too, and that is what
-- makes a deferred window bounded: one source read per write rather than one
-- per request. What bounds the reuse is the marker.
do
  local state = new_projection_state()
  local projection
  local before

  state.versions.route_alias_source = 200
  state.route_alias = {
    {source = 'content/2', alias = 'deferred-alias', language = 'all'},
  }

  setup_route_env(state)
  projection = require 'includes.projection'
  route_aliases_load()

  assert_eq('route_pending_serves_from_source', ophal.aliases.source['content/2'], 'deferred-alias')
  assert_eq('route_pending_queued', queued_rebuilds(state), 'route_alias_index')

  before = query_count(state, ALIAS_SOURCE_READ)
  route_aliases_load()

  assert_eq('route_pending_fallback_reused', query_count(state, ALIAS_SOURCE_READ), before)

  -- With the marker gone and the index version unmoved, a worker that kept
  -- trusting its fallback load would never ask about this projection again. So
  -- the reuse ends with the marker: the next request goes back to `ensure()`,
  -- which is what decides whether to queue, rebuild, or defer again.
  projection.clear_pending('route_alias_index')
  route_aliases_load()

  assert_eq('route_pending_lapsed_reloads', query_count(state, ALIAS_SOURCE_READ), before + 1)
  assert_eq(
    'route_pending_lapsed_asks_again',
    projection.rebuild_pending('route_alias_index') ~= nil,
    true
  )
end

-- With no versions and no marker there is nothing to compare, and the guard
-- says so: such a site reloads on every request, exactly as it did before the
-- guard existed.
do
  local state = new_projection_state()
  local before

  state.route_alias = {
    {source = 'content/9', alias = 'unversioned-alias', language = 'all'},
  }

  setup_route_env(state, {ensure = function() return false end})
  route_aliases_load()

  before = query_count(state, ALIAS_SOURCE_READ)
  route_aliases_load()

  assert_eq(
    'route_unversioned_reloads_every_request',
    query_count(state, ALIAS_SOURCE_READ),
    before + 1
  )
  assert_eq('route_unversioned_alias_loaded', ophal.aliases.source['content/9'], 'unversioned-alias')
end

-- Redirects are loaded beside the aliases on the same request path and answer
-- to the same guard, on their own pair of versions.
do
  local state = new_projection_state()
  local read = '^SELECT %* FROM route_index WHERE kind = %?$'
  local before

  state.versions.route_redirect_index = 100
  state.versions.route_redirect_source = 90
  state.route_index.redirect = {
    {source = 'old-path', target = 'new-path', language = 'all', type = 301},
  }

  setup_route_env(state)
  route_redirects_load()

  before = query_count(state, read, 'redirect')
  assert_eq('route_redirect_first_load_reads_index', before, 1)

  route_redirects_load()

  assert_eq('route_redirect_reload_skipped_when_unchanged', query_count(state, read, 'redirect'), before)
  assert_eq('route_redirect_reload_keeps_target', ophal.redirects.source['old-path'][1], 'new-path')
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

  local original = make_db_query(state)
  local db_query
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
  -- The wrapper has to reach the connection as well as the free function, or
  -- half the reads would go round the table this case is making disappear.
  db_fake.install({sql = db_query}, env, _G)
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

  assert_eq('content_projection_frontpage_count_query', query_count(state, '^SELECT count%(%*%) AS total FROM content_public'), 1)
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
  assert_eq('frontpage_clamp_single_count_query', query_count(state, '^SELECT count%(%*%) AS total FROM content_public'), 1)

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

  -- The stale row is not served and the rebuild does not happen here. The
  -- request reads the one entity it needs from the normalized table -- bounded
  -- work -- and queues the unbounded part.
  assert_eq('content_stale_serves_from_source', entity.title, 'Fresh legacy row')
  assert_eq('content_stale_queued', queued_rebuilds(state), 'content_public')
  assert_eq('content_stale_did_not_rebuild', query_count(state, '^SELECT %* FROM content$'), 0)
  assert_eq('content_stale_version_unmoved', state.versions.content_public, 300)
  -- Not even the single row it just loaded: writing it would touch
  -- `content_public`, and a touch is what tells every other reader the whole
  -- projection is current.
  assert_eq('content_stale_no_backfill', state.content_public[9].title, 'Stale projected row')

  run_queued_rebuild('content_public')

  assert_eq('content_stale_rebuilt_row', state.content_public[9].title, 'Fresh legacy row')
  assert_eq('content_stale_rebuilt_from_source', query_count(state, '^SELECT %* FROM content$'), 1)
  -- The rebuild records the source version it just read, and stamps it with the
  -- same value as the projection. An absent or trailing `content_source` row is
  -- re-read every time the miss cache lapses, on every anonymous page.
  assert_eq('content_stale_rebuild_marks_source',
    state.versions.content_source, state.versions.content_public)
end

-- A rebuild is `N + 3` statements, not `3N + 3`. Same reasoning as the route
-- rebuild above: the whole table has just been emptied, so the per-row DELETE
-- finds nothing, and the per-row version touch writes the value the final touch
-- writes anyway.
do
  local state = new_projection_state()
  local content

  state.versions.content_source = 500
  for id = 1, 3 do
    state.content_rows[id] = {
      id = id,
      user_id = 1,
      title = 'Row ' .. id,
      teaser = 'T',
      body = 'B',
      status = 1,
      promote = 1,
      created = 10,
    }
  end

  content = setup_content_env(state)
  content.frontpage()
  run_queued_rebuild('content_public')

  assert_eq(
    'content_rebuild_clears_table_once',
    query_count(state, '^DELETE FROM content_public$'),
    1
  )
  assert_eq(
    'content_rebuild_skips_per_row_delete',
    query_count(state, '^DELETE FROM content_public WHERE id = %?$'),
    0
  )
  assert_eq(
    'content_rebuild_inserts_each_row',
    query_count(state, '^INSERT INTO content_public'),
    3
  )
  -- Two touches for three rows: `content_public` and `content_source`.
  assert_eq(
    'content_rebuild_touches_each_version_once',
    query_count(state, '^INSERT INTO projection_version%('),
    2
  )
end

-- A miss in a usable projection is worth backfilling; a miss in one that is not
-- usable is not. The distinction is what keeps a single page view from stamping
-- `content_public` complete while it holds one row -- see `load()`.
do
  local state = new_projection_state()
  local content

  state.versions.content_public = 300
  state.versions.content_source = 300
  state.content_rows[7] = {
    id = 7,
    user_id = 1,
    title = 'Not yet projected',
    teaser = 'T',
    body = 'B',
    status = 1,
    promote = 1,
    created = 10,
  }

  content = setup_content_env(state)
  content.load(7)

  assert_eq('content_backfill_writes_row', state.content_public[7] ~= nil, true)
end

do
  local state = new_projection_state()
  local content

  state.versions.content_public = 300
  state.versions.content_source = 300
  state.content_rows[8] = {
    id = 8,
    user_id = 1,
    title = 'Not yet projected',
    teaser = 'T',
    body = 'B',
    status = 1,
    promote = 1,
    created = 10,
  }

  -- Force the answer `ensure()` cannot give yet: the projection exists but is
  -- not usable, because its rebuild has not happened.
  content = setup_content_env(state, {ensure = function() return false end})

  content.load(8)

  assert_eq('content_backfill_skipped_when_unusable', state.content_public[8], nil)
  assert_eq(
    'content_backfill_touches_no_version',
    query_count(state, '^INSERT INTO projection_version%('),
    0
  )
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

  assert_eq('tag_projection_count_query', query_count(state, '^SELECT COUNT%(%*%) AS total FROM tag_listing_index'), 1)
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

  -- The listing projection is the most expensive rebuild in the codebase: a
  -- full DELETE followed by one INSERT per tags-by-content join row, reached
  -- from the tags menu that renders on every page. So it is the one that most
  -- needs to be queued rather than run from inside a page view.
  state.content_rows[5] = {
    id = 5,
    user_id = 1,
    title = 'Projected tagged content',
    teaser = 'Projected teaser',
    body = 'Projected body',
    status = 1,
    promote = 1,
    created = 20,
  }

  tag_mod = setup_tag_env(state)
  -- `entity_page()` returns the theme closure; calling it is what renders.
  tag_mod.entity_page()()

  assert_eq('tag_deferred_queued', queued_rebuilds(state), 'tag_listing_index')
  assert_eq('tag_deferred_wrote_no_rows', #state.tag_listing_index, 0)
  assert_eq('tag_deferred_version_unmoved', state.versions.tag_listing_index, nil)
  -- Served anyway, from the normalized join the fallback has always used.
  -- Indexed defensively: a listing that renders nothing should name itself
  -- rather than crash the file on `rows[1]`, which is how a broken count
  -- surfaces here.
  assert_eq(
    'tag_deferred_page_rendered',
    state.rendered_tag_page
      and (state.rendered_tag_page.rows[1] or {}).title,
    'Projected tagged content'
  )

  run_queued_rebuild('tag_listing_index')

  assert_eq('tag_deferred_rebuild_rows', #state.tag_listing_index, 1)
  assert_eq('tag_deferred_rebuild_touched', state.versions.tag_listing_index ~= nil, true)
  assert_eq('tag_deferred_rebuild_title', state.tag_listing_index[1].title, 'Projected tagged content')
  -- A rebuild records the source version it just read. An absent version row is
  -- re-queried every time the miss cache lapses, so a site whose tags never went
  -- through the entity hooks would pay a `projection_version` SELECT forever.
  assert_eq('tag_deferred_rebuild_marks_source',
    state.versions.tag_listing_source, state.versions.tag_listing_index)
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

  -- The stale listing is left exactly as it was. It is the cascade that makes
  -- this one matter: `tag_listing_index` declares `content_public` as a
  -- dependency, so before deferral a content rebuild pulled a full tag rebuild
  -- into the same request.
  assert_eq('tag_stale_queued', queued_rebuilds(state), 'tag_listing_index')
  assert_eq('tag_stale_index_untouched', state.tag_listing_index[1].title, 'Stale projected tagged content')
  assert_eq('tag_stale_version_unmoved', state.versions.tag_listing_index, 600)
  assert_eq(
    'tag_stale_did_not_read_join',
    query_count(state, "^SELECT t%.id tag_id, t%.name tag_name, 'content' entity_type, cp%.id entity_id,"),
    0
  )

  run_queued_rebuild('tag_listing_index')

  assert_eq('tag_stale_rebuilt_title', state.tag_listing_index[1].title, 'Fresh projected tagged content')
  assert_eq(
    'tag_stale_rebuild_source_query',
    query_count(state, "^SELECT t%.id tag_id, t%.name tag_name, 'content' entity_type, cp%.id entity_id,"),
    1
  )
end

io.write '\n-- tag entity load cache --\n'

-- `entity_load()` runs on every entity load, so before this cache a content
-- page paid one `field_tag` join per request. That was the last normalized
-- query the end-to-end smoke budget measured in an anonymous render.
do
  local state = new_projection_state()
  local tag_mod
  local first, second

  state.versions.tag_listing_source = 100
  state.tag_rows[1] = {id = 1, name = 'alpha'}
  state.tag_rows[2] = {id = 2, name = 'beta'}
  state.field_tag_rows = {
    {entity_type = 'content', entity_id = 7, tag_id = 1},
    {entity_type = 'content', entity_id = 7, tag_id = 2},
  }

  tag_mod = setup_tag_env(state)

  first = {type = 'content', id = 7}
  tag_mod.entity_load(first)
  second = {type = 'content', id = 7}
  tag_mod.entity_load(second)

  assert_eq('tag_entity_load_first_name', first.tags[1], 'alpha')
  assert_eq('tag_entity_load_second_name', first.tags[2], 'beta')
  assert_eq('tag_entity_load_warm_name', second.tags[1], 'alpha')
  assert_eq('tag_entity_load_query_count',
    query_count(state, '^SELECT t%.%* FROM field_tag'), 1)
end

-- The entity is part of the cache key, so two entities must not be served each
-- other's tags. A key that dropped the id would pass every test above.
do
  local state = new_projection_state()
  local tag_mod
  local alpha_entity, beta_entity

  state.versions.tag_listing_source = 100
  state.tag_rows[1] = {id = 1, name = 'alpha'}
  state.tag_rows[2] = {id = 2, name = 'beta'}
  state.field_tag_rows = {
    {entity_type = 'content', entity_id = 7, tag_id = 1},
    {entity_type = 'content', entity_id = 8, tag_id = 2},
  }

  tag_mod = setup_tag_env(state)

  alpha_entity = {type = 'content', id = 7}
  beta_entity = {type = 'content', id = 8}
  tag_mod.entity_load(alpha_entity)
  tag_mod.entity_load(beta_entity)

  assert_eq('tag_entity_load_keyed_by_entity', beta_entity.tags[2], 'beta')
  assert_eq('tag_entity_load_no_bleed', beta_entity.tags[1], nil)
end

-- The cached table outlives the request, and the entity it lands on is
-- editable: the tag form element hands `form.entity.tags` straight to a caller.
-- Handing out the cached table itself would let one request's edit become every
-- later request's tag set.
do
  local state = new_projection_state()
  local tag_mod
  local first, second

  state.versions.tag_listing_source = 100
  state.tag_rows[1] = {id = 1, name = 'alpha'}
  state.field_tag_rows = {
    {entity_type = 'content', entity_id = 7, tag_id = 1},
  }

  tag_mod = setup_tag_env(state)

  first = {type = 'content', id = 7}
  tag_mod.entity_load(first)
  first.tags[1] = 'edited'
  first.tags[99] = 'invented'

  second = {type = 'content', id = 7}
  tag_mod.entity_load(second)

  assert_eq('tag_entity_load_copy_unedited', second.tags[1], 'alpha')
  assert_eq('tag_entity_load_copy_no_leak', second.tags[99], nil)
end

-- The load-bearing test for the version key. `tag_projection_refresh_ids()`
-- returns without touching `tag_listing_index` when the configured entity types
-- are not the shape the listing projection supports, but the `field_tag` rows
-- were rewritten all the same. A cache keyed on the index version would serve
-- the pre-write tag set until something else moved it; `tag_listing_source` is
-- touched on every write, which is why the cache keys on that instead.
do
  local state = new_projection_state()
  local tag_mod
  local after

  state.tag_rows[1] = {id = 1, name = 'alpha'}
  state.tag_rows[2] = {id = 2, name = 'beta'}
  state.field_tag_rows = {
    {entity_type = 'content', entity_id = 7, tag_id = 1},
  }

  tag_mod = setup_tag_env(state, {content = true, comment = true})

  tag_mod.entity_load({type = 'content', id = 7})
  tag_mod.entity_after_save({type = 'content', id = 7, tags = {2}})

  after = {type = 'content', id = 7}
  tag_mod.entity_load(after)

  assert_eq('tag_entity_load_unsupported_index_untouched',
    state.versions.tag_listing_index, nil)
  assert_eq('tag_entity_load_unsupported_source_moved',
    state.versions.tag_listing_source ~= nil, true)
  assert_eq('tag_entity_load_write_drops_alpha', after.tags[1], nil)
  assert_eq('tag_entity_load_write_adds_beta', after.tags[2], 'beta')
end

-- The same invalidation on the supported shape, where the write also rebuilds
-- the listing. This is the arm that goes red if `entity_after_save()` stops
-- marking the source.
do
  local state = new_projection_state()
  local tag_mod
  local after

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

  tag_mod.entity_load({type = 'content', id = 7})
  tag_mod.entity_after_save({type = 'content', id = 7, tags = {2}})

  after = {type = 'content', id = 7}
  tag_mod.entity_load(after)

  assert_eq('tag_entity_load_supported_drops_alpha', after.tags[1], nil)
  assert_eq('tag_entity_load_supported_adds_beta', after.tags[2], 'beta')
end

-- An entity type the site has not configured for tagging is left alone, cache
-- or no cache: the hook must not invent a `tags` field on it.
do
  local state = new_projection_state()
  local tag_mod
  local entity

  state.versions.tag_listing_source = 100
  state.tag_rows[1] = {id = 1, name = 'alpha'}
  state.field_tag_rows = {
    {entity_type = 'comment', entity_id = 7, tag_id = 1},
  }

  tag_mod = setup_tag_env(state)

  entity = {type = 'comment', id = 7}
  tag_mod.entity_load(entity)

  assert_eq('tag_entity_load_skips_unconfigured', entity.tags, nil)
  assert_eq('tag_entity_load_skips_unconfigured_query',
    query_count(state, '^SELECT t%.%* FROM field_tag'), 0)
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

do
  local state = tag_listing_state()
  local tag_mod

  -- The count comes from the projection and the rows read then fails, which is
  -- the only order in which the legacy UNION arms are still unbuilt by the time
  -- the fallback needs them. The fallback used to concatenate the empty arm
  -- list and send a bare ' ORDER BY created DESC LIMIT ?, ?'.
  state.fail_query = '^SELECT entity_type type'
  tag_mod = setup_tag_env(state)
  tag_mod.entity_page()

  assert_eq('tag_listing_rows_fallback_no_bare_order',
    query_count(state, '^ ORDER BY created DESC'), 0)
  assert_eq('tag_listing_rows_fallback_builds_arms',
    query_count(state, '^SELECT entity_type FROM field_tag'), 1)
  assert_eq('tag_listing_rows_fallback_union_query',
    query_count(state, "^SELECT '[%w_]+' type, e%.id id,"), 1)
end

--[[ A tag on two entity types, served from the normalized fallback.

  This path had never run with more than one arm, and it could not have: `e.*`
  on two different tables gives two different column counts, so the UNION was a
  syntax error rather than a wrong answer; each arm binds its own
  `ft.tag_id = ?`, and the call sites passed one parameter however many arms
  there were; and the count read the first row of a UNION, so a tag on two types
  reported one of the two counts -- which decides how many pages the listing
  has.

  Only `content` is a tagged entity type in the measured profile, which is why
  none of that showed up anywhere.
]]
do
  local state = new_projection_state()
  local tag_mod
  local count_query

  state.tag_rows[1] = {id = 1, name = 'alpha', description = 'Alpha'}
  state.content_rows[5] = {
    id = 5,
    user_id = 1,
    title = 'Tagged content',
    teaser = 'Content teaser',
    body = 'Content body',
    status = 1,
    promote = 1,
    created = 20,
  }
  state.entity_rows.page = {
    [7] = {
      id = 7,
      user_id = 1,
      title = 'Tagged page',
      teaser = 'Page teaser',
      body = 'Page body',
      status = 1,
      promote = 1,
      created = 30,
    },
  }
  state.field_tag_rows = {
    {entity_type = 'content', entity_id = 5, tag_id = 1},
    {entity_type = 'page', entity_id = 7, tag_id = 1},
  }

  -- No listing projection at all, so the fallback is the only path. One item
  -- per page, so the count decides the page count and a count that read one
  -- arm instead of both is visible in it.
  tag_mod = setup_tag_env(state, {content = true, page = true})
  settings.tag.items_per_page = 1
  state.fail_query = 'tag_listing_index'
  tag_mod.entity_page()()

  for _, entry in ipairs(state.queries) do
    if entry.sql:match('^SELECT SUM%(total%) AS total FROM %(') then
      count_query = entry
    end
  end

  assert_eq('tag_two_types_count_query_issued', count_query ~= nil, true)
  -- One bind parameter per arm. With one, the second arm had no value.
  assert_eq('tag_two_types_count_binds_one_id_per_arm',
    count_query and #count_query.params, 2)
  assert_eq('tag_two_types_count_binds_the_tag_id',
    count_query and count_query.params[2], 1)
  -- Two entities at one per page. Reading the first row of the union gave one.
  assert_eq('tag_two_types_count_sums_the_arms',
    state.pager and state.pager.pages, 2)
  assert_eq('tag_two_types_union_is_all',
    count_query and count_query.sql:find('UNION ALL', 1, true) ~= nil, true)

  -- Page one holds the newest row, and it comes from the second arm.
  assert_eq('tag_two_types_rows_rendered',
    state.rendered_tag_page and #state.rendered_tag_page.rows, 1)
  assert_eq('tag_two_types_first_row_is_newest',
    state.rendered_tag_page and state.rendered_tag_page.rows[1].title,
    'Tagged page')
  assert_eq('tag_two_types_first_row_type',
    state.rendered_tag_page and state.rendered_tag_page.rows[1].type, 'page')
  -- The projection carries `route`; the fallback builds the same value, so the
  -- two branches hand the page one shape.
  assert_eq('tag_two_types_route_filled',
    state.rendered_tag_page and state.rendered_tag_page.rows[1].route, 'page/7')
end

io.write '\n-- deferred rebuild markers --\n'

-- The marker is the piece version numbers cannot supply. Everything below is
-- about one property: while a rebuild is queued, the projection is not usable
-- and nothing may say otherwise.
do
  local state = new_projection_state()
  local projection

  state.versions.content_public = 500
  state.versions.content_source = 500

  setup_content_env(state)
  projection = require 'includes.projection'

  -- Fresh by every version comparison there is.
  assert_eq('pending_absent_reads_fresh', projection.ensure('content_public', function() end, {
    depends_on = {'content_source'},
  }), true)

  projection.mark_pending('content_public', 500)

  -- And not usable anyway, because a queued rebuild outranks the comparison.
  -- This is the case the whole design turns on: a projection can be complete by
  -- its version and a fraction of itself in fact.
  assert_eq('pending_marker_outranks_version', projection.ensure('content_public', function() end, {
    depends_on = {'content_source'},
  }), false)

  assert_eq('pending_marker_readable', projection.rebuild_pending('content_public'), 500)

  projection.clear_pending('content_public')
  assert_eq('pending_marker_cleared', projection.rebuild_pending('content_public'), nil)
  assert_eq('pending_cleared_reads_fresh', projection.ensure('content_public', function() end, {
    depends_on = {'content_source'},
  }), true)
end

-- A site with no cron scheduled must not be stuck on the fallback forever. The
-- marker expiring is what makes a worker ask again; it is not by itself what
-- rescues the site, which is the next section.
do
  local state = new_projection_state()
  local projection

  setup_content_env(state)
  settings.performance = {projection_rebuild_pending_ttl = 0}
  projection = require 'includes.projection'

  projection.mark_pending('content_public', 100)
  assert_eq('pending_marker_expires', projection.rebuild_pending('content_public'), nil)
end

io.write '\n-- a queue that stopped draining --\n'

-- The failure this closes. A lapsed marker sends the request back to `ensure()`,
-- which enqueues -- and `enqueue()` reports success for landing on the row
-- already there exactly as it does for writing a new one, because to the queue
-- those are the same outcome. So the request re-marked and waited another full
-- TTL, forever, on any site whose cron was never scheduled, was misconfigured,
-- or was refused by the token gate. Correct pages the whole time, from the
-- normalized fallback, which is why nothing ever surfaced it.
do
  local state = new_projection_state()
  local content, projection, entity

  local pending_ttl = 900
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
  -- A rebuild queued long enough ago that its marker has lapsed more than once,
  -- still live because nothing has taken it off the queue.
  state.jobs[1] = {
    kind = 'projection_rebuild',
    dedup_key = 'content_public',
    active_key = 'content_public',
    created_at = os.time() - 5000,
  }

  content = setup_content_env(state)
  -- After `setup_content_env()`, which installs a fresh `settings` table.
  settings.performance = {projection_rebuild_pending_ttl = pending_ttl}
  projection = require 'includes.projection'
  projection.clear_pending('content_public')

  entity = content.load(9)

  assert_eq('stalled_queue_rebuilds_inline', state.content_public[9].title, 'Fresh legacy row')
  assert_eq('stalled_queue_serves_fresh', entity.title, 'Fresh legacy row')
  assert_eq('stalled_queue_moves_version',
    state.versions.content_public, state.versions.content_source)
  -- Nothing is marked pending, because there is nothing outstanding: the
  -- rebuild the marker would have been describing has just run.
  assert_eq('stalled_queue_marks_nothing', projection.rebuild_pending('content_public'), nil)
  -- The job row is left where it is. This is not the runner, and a drain that
  -- comes back later and rebuilds once more costs nothing, while deleting the
  -- row here would erase the evidence that the queue ever stopped.
  assert_eq('stalled_queue_leaves_the_job', #state.jobs, 1)
end

-- The boundary. A job younger than the marker's lifetime is a queue that has
-- simply not been drained yet, which is the ordinary state during a deferred
-- window and must keep deferring. Only a job that has outlived the marker is
-- evidence, because only then is it certain the marker lapsed with nothing
-- having run in between.
do
  local state = new_projection_state()
  local content, projection

  local pending_ttl = 900
  state.versions.content_public = 300
  state.versions.content_source = 400
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
  state.jobs[1] = {
    kind = 'projection_rebuild',
    dedup_key = 'content_public',
    active_key = 'content_public',
    created_at = os.time() - 900,
  }

  content = setup_content_env(state)
  -- After `setup_content_env()`, which installs a fresh `settings` table.
  settings.performance = {projection_rebuild_pending_ttl = pending_ttl}
  projection = require 'includes.projection'
  projection.clear_pending('content_public')

  content.load(9)

  assert_eq('queue_at_the_ttl_still_defers', state.versions.content_public, 300)
  assert_eq('queue_at_the_ttl_marks_pending',
    projection.rebuild_pending('content_public'), 400)

  projection.clear_pending('content_public')
end

-- A first deferral is never stalled: the row `enqueue()` just wrote is seconds
-- old. Without this the age check would turn every deferral into the inline
-- rebuild the phase exists to avoid, and no budget in the smoke suite would
-- have moved to say so.
do
  local state = new_projection_state()
  local content, projection

  local pending_ttl = 900
  state.versions.content_public = 300
  state.versions.content_source = 400
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
  -- After `setup_content_env()`, which installs a fresh `settings` table.
  settings.performance = {projection_rebuild_pending_ttl = pending_ttl}
  projection = require 'includes.projection'
  projection.clear_pending('content_public')

  content.load(9)

  assert_eq('first_deferral_not_stalled', state.versions.content_public, 300)
  assert_eq('first_deferral_queued', queued_rebuilds(state), 'content_public')
  assert_eq('first_deferral_marks_pending',
    projection.rebuild_pending('content_public'), 400)

  projection.clear_pending('content_public')
end

-- A TTL of zero is not a lapse. `ngx.shared`'s `set` reads an expiry of 0 as
-- "no expiry", so a marker written under it stands until something clears it --
-- a deliberate choice to defer indefinitely, not a drain that has stopped. The
-- age of the job says nothing about that choice, however old it is.
do
  local state = new_projection_state()
  local content, projection

  local pending_ttl = 0
  state.versions.content_public = 300
  state.versions.content_source = 400
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
  state.jobs[1] = {
    kind = 'projection_rebuild',
    dedup_key = 'content_public',
    active_key = 'content_public',
    created_at = os.time() - 100000,
  }

  content = setup_content_env(state)
  -- After `setup_content_env()`, which installs a fresh `settings` table.
  settings.performance = {projection_rebuild_pending_ttl = pending_ttl}
  projection = require 'includes.projection'
  projection.clear_pending('content_public')

  content.load(9)

  assert_eq('zero_ttl_never_stalls', state.versions.content_public, 300)

  projection.clear_pending('content_public')
  settings.performance = {}
end

-- An unmigrated site has no queue to read an age from, and must not start
-- raising because of it. `enqueue()` already answers false there and the
-- inline rebuild happens for that reason; the age check must not be reached in
-- a way that turns a missing table into an error.
do
  local state = new_projection_state()
  local content

  local pending_ttl = 900
  state.jobs_absent = true
  state.versions.content_public = 300
  state.versions.content_source = 400
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
  settings.performance = {projection_rebuild_pending_ttl = pending_ttl}
  require('includes.projection').clear_pending('content_public')

  content.load(9)

  assert_eq('unmigrated_queue_rebuilds_inline',
    state.content_public[9].title, 'Fresh legacy row')
end

-- Deferring records the marker, and the runner clears it. Clearing has to
-- happen before the rebuild runs, not after: the rebuild ends by touching its
-- own version, and every incremental write is suspended while the marker
-- stands.
do
  local state = new_projection_state()
  local projection
  local pending_during_rebuild

  state.versions.content_public = 300
  state.versions.content_source = 400
  state.content_rows[1] = {
    id = 1,
    user_id = 1,
    title = 'Row',
    teaser = 'T',
    body = 'B',
    status = 1,
    promote = 1,
    created = 10,
  }

  local content = setup_content_env(state)
  projection = require 'includes.projection'

  content.frontpage()
  assert_eq('defer_marks_pending', projection.rebuild_pending('content_public'), 400)

  projection.register_rebuild('probe', function()
    pending_during_rebuild = projection.rebuild_pending('probe')
    return true
  end)
  projection.mark_pending('probe', 1)
  projection.run_rebuild('probe')

  assert_eq('run_rebuild_clears_marker_first', pending_during_rebuild, nil)

  run_queued_rebuild('content_public')
  assert_eq('rebuild_clears_pending', projection.rebuild_pending('content_public'), nil)
end

-- An unknown projection key is an error the runner reports, not a raise. A job
-- carrying a key no module registered would otherwise take the drain down and,
-- through `module_invoke_all()`, every other module's cron hook with it.
do
  local state = new_projection_state()
  local projection

  setup_content_env(state)
  projection = require 'includes.projection'

  local ok, err = projection.run_rebuild('not_a_projection')
  assert_eq('run_rebuild_unknown_key_nil', ok, nil)
  assert_match('run_rebuild_unknown_key_error', err, 'no rebuild registered')
end

-- While a rebuild is queued, a save stops maintaining the projection
-- incrementally. Writing the row would be wasted -- the rebuild rewrites every
-- row -- and the version touch that comes with it is the actual hazard: a
-- version is all `ensure()` compares, so one incremental touch would announce
-- that a projection holding a fraction of its rows is complete.
do
  local state = new_projection_state()
  local content
  local projection

  state.versions.content_public = 300
  state.versions.content_source = 300
  state.content_rows[3] = {
    id = 3,
    user_id = 1,
    title = 'Saved while a rebuild was queued',
    teaser = 'T',
    body = 'B',
    status = 1,
    promote = 1,
    created = 10,
  }

  content = setup_content_env(state)
  projection = require 'includes.projection'
  projection.mark_pending('content_public', 300)

  local versions_before = query_count(state, '^INSERT INTO projection_version%(')
  content.entity_after_save({type = 'content', id = 3})

  assert_eq('save_while_pending_writes_no_row', state.content_public[3], nil)
  assert_eq(
    'save_while_pending_touches_no_version',
    query_count(state, '^INSERT INTO projection_version%(') - versions_before,
    0
  )

  -- And once the rebuild has run, the same save maintains it again.
  projection.clear_pending('content_public')
  content.entity_after_save({type = 'content', id = 3})
  assert_eq(
    'save_after_rebuild_writes_row',
    state.content_public[3].title,
    'Saved while a rebuild was queued'
  )
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
  install_db(state, _G)
  if shared then
    -- `ctx` as well as `shared`: `includes/request_state.lua` reads `ngx.ctx`
    -- whenever `ngx` is present, and `includes/http_cache.lua` records every
    -- projection version read through it. A stub with only the shared dict is
    -- not a runtime this codebase would ever meet.
    ngx = {shared = {ophal_projection_versions = shared}, ctx = {}}
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

io.write '\n-- payload cache stats --\n'

-- Counting is off by default, because it is per-lookup bookkeeping on the hot
-- path. Occupancy is not: bucket sizes are maintained either way, and reading
-- `entries` against `limit` is how an operator decides whether the size a site
-- configured is the right one for it.
do
  local state = new_projection_state()
  local projection
  local loads, loader_for = counting_loader()
  local stats

  state.versions.content_public = 400
  projection = setup_projection_env(state)

  projection.cached_value('content_public', 'a', loader_for('a'))
  projection.cached_value('content_public', 'a', loader_for('a'))
  stats = projection.cache_stats()

  assert_eq('cache_stats_off_no_hits', stats.hits, 0)
  assert_eq('cache_stats_off_no_misses', stats.misses, 0)
  assert_eq('cache_stats_off_reports_entries', stats.entries, 1)
  assert_eq('cache_stats_off_reports_limit', stats.limit, 512)
end

-- With counting on, a lookup lands in exactly one bucket, and the per-
-- projection breakdown is what names which read model is missing.
do
  local state = new_projection_state()
  local projection
  local loads, loader_for = counting_loader()
  local stats

  state.versions.content_public = 400
  projection = setup_projection_env(state)
  settings.performance = {projection_cache_stats = true}

  projection.cached_value('content_public', 'a', loader_for('a'))
  projection.cached_value('content_public', 'a', loader_for('a'))
  projection.cached_value('content_public', 'b', loader_for('b'))
  stats = projection.cache_stats()

  assert_eq('cache_stats_counts_hits', stats.hits, 1)
  assert_eq('cache_stats_counts_misses', stats.misses, 2)
  assert_eq('cache_stats_names_projection', stats.projections.content_public.hits, 1)
  assert_eq('cache_stats_names_entries', stats.projections.content_public.entries, 2)
end

-- A key that is present but out of date is a different diagnosis from a key
-- that is absent: raising the size fixes the second and does nothing for the
-- first. Lumping them together would report a cache too small when what is
-- really happening is that writes are outpacing reads.
do
  local state = new_projection_state()
  local shared = new_shared_dict()
  local projection
  local loads, loader_for = counting_loader()
  local stats

  shared.store.content_public = 1
  projection = setup_projection_env(state, shared)
  settings.performance = {projection_cache_stats = true}

  projection.cached_value('content_public', 'a', loader_for('a'))

  -- Another worker writes and bumps the shared version.
  shared.store.content_public = 2
  projection.cached_value('content_public', 'a', loader_for('a'))
  stats = projection.cache_stats()

  assert_eq('cache_stats_counts_stale', stats.stale, 1)
  assert_eq('cache_stats_stale_is_not_a_miss', stats.misses, 1)
end

-- Evictions are the signal the bound is biting. Without them a bucket that is
-- churning looks the same as one serving a working set that never fit.
do
  local state = new_projection_state()
  local projection
  local loads, loader_for = counting_loader()
  local stats

  state.versions.content_public = 400
  projection = setup_projection_env(state)
  settings.performance = {
    projection_cache_stats = true,
    projection_payload_cache_size = 2,
  }

  for _, key in ipairs{'a', 'b', 'c'} do
    projection.cached_value('content_public', key, loader_for(key))
  end
  stats = projection.cache_stats()

  assert_eq('cache_stats_counts_evictions', stats.evictions, 1)
  assert_eq('cache_stats_names_evictions', stats.projections.content_public.evictions, 1)
  assert_eq('cache_stats_entries_stay_bounded', stats.entries, 2)
end

-- A cache turned off still accounts for its lookups, so hits plus misses plus
-- stale stays the number of lookups and the report reads as the zero hit rate
-- it is rather than as no traffic.
do
  local state = new_projection_state()
  local projection
  local loads, loader_for = counting_loader()
  local stats

  state.versions.content_public = 400
  projection = setup_projection_env(state)
  settings.performance = {
    projection_cache_stats = true,
    projection_payload_cache_size = 0,
  }

  projection.cached_value('content_public', 'a', loader_for('a'))
  projection.cached_value('content_public', 'a', loader_for('a'))
  stats = projection.cache_stats()

  assert_eq('cache_stats_disabled_counts_misses', stats.misses, 2)
  assert_eq('cache_stats_disabled_no_hits', stats.hits, 0)
end

-- Dropping the payloads is the normal consequence of a write, so it must not
-- take the measurement with it. Only an explicit reset does that, and the reset
-- re-reads the setting the way the query classifier's does.
do
  local state = new_projection_state()
  local projection
  local loads, loader_for = counting_loader()

  state.versions.content_public = 400
  projection = setup_projection_env(state)
  settings.performance = {projection_cache_stats = true}

  projection.cached_value('content_public', 'a', loader_for('a'))
  projection.cached_value('content_public', 'a', loader_for('a'))
  projection_cache_clear()

  assert_eq('cache_stats_survive_cache_clear', projection.cache_stats().hits, 1)
  assert_eq('cache_stats_clear_drops_entries', projection.cache_stats().entries, 0)

  projection.cache_stats_reset()
  assert_eq('cache_stats_reset_zeroes_counts', projection.cache_stats().hits, 0)

  settings.performance = {projection_cache_stats = false}
  projection.cache_stats_reset()
  projection.cached_value('content_public', 'a', loader_for('a'))
  assert_eq('cache_stats_reset_rereads_setting', projection.cache_stats().misses, 0)
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

-- The classifier is the definition every budget in this file and in the smoke
-- suite rests on, so its blind spots are budget bugs rather than reporting
-- ones. `projection.touch()`'s upsert found one: `DO UPDATE SET` put the
-- keyword after `UPDATE`, the scanner read `set` as a table, and because no
-- projection is named `set` every touch counted as a normalized write. These
-- pin the shapes the codebase actually issues.
io.write('\n-- query classifier --\n')

do
  local function names_of(sql)
    return table.concat(db_stats.tables(sql), ',')
  end

  assert_eq(
    'stats_tables_upsert',
    names_of([[
INSERT INTO projection_version(projection_key, version, updated_at) VALUES(?, ?, ?)
ON CONFLICT(projection_key) DO UPDATE SET
  version = excluded.version,
  updated_at = excluded.updated_at]]),
    'projection_version'
  )

  -- The guard above must not cost a real UPDATE its table. `SET` is skipped
  -- only where it follows `UPDATE`; here the table already did.
  assert_eq(
    'stats_tables_update',
    names_of('UPDATE users SET pass = ? WHERE id = ?'),
    'users'
  )

  assert_eq(
    'stats_tables_join',
    names_of('SELECT t.* FROM field_tag ft JOIN tag t ON t.id = ft.tag_id'),
    'field_tag,tag'
  )

  assert_eq(
    'stats_tables_derived',
    names_of('SELECT * FROM (SELECT id FROM content) c'),
    'content'
  )

  assert_eq(
    'stats_tables_insert_values',
    names_of('INSERT INTO field_tag(entity_type, entity_id, tag_id) VALUES(?, ?, ?)'),
    'field_tag'
  )
end

-- The queue is neither a read model nor site data. Deferral puts an enqueue on
-- the read path on purpose, so that write has to be countable without moving
-- the number Phase 4 holds at zero -- and without disappearing into the number
-- that is allowed to be non-zero on a warm page.
do
  local function bucket_of(sql)
    local snapshot

    db_stats.reset()
    settings = {performance = {query_stats = true}}
    db_stats.record(sql)
    snapshot = db_stats.snapshot()

    if snapshot.normalized > 0 then
      return 'normalized'
    elseif snapshot.infrastructure > 0 then
      return 'infrastructure'
    elseif snapshot.projection > 0 then
      return 'projection'
    end

    return 'none'
  end

  assert_eq(
    'stats_bucket_jobs_enqueue',
    bucket_of([[
INSERT INTO ophal_jobs(kind, dedup_key, active_key) VALUES(?, ?, ?)
ON CONFLICT(active_key) DO NOTHING]]),
    'infrastructure'
  )

  assert_eq(
    'stats_bucket_jobs_claim',
    bucket_of('UPDATE ophal_jobs SET status = ? WHERE id IN (SELECT id FROM ophal_jobs)'),
    'infrastructure'
  )

  assert_eq(
    'stats_bucket_migrations',
    bucket_of('SELECT id FROM ophal_migrations'),
    'infrastructure'
  )

  assert_eq(
    'stats_bucket_projection_still_projection',
    bucket_of('SELECT * FROM content_public WHERE id = ?'),
    'projection'
  )

  assert_eq(
    'stats_bucket_normalized_still_normalized',
    bucket_of('SELECT * FROM content WHERE id = ?'),
    'normalized'
  )

  -- Ordering, not addition. A rebuild reads source data and writes the queue in
  -- one statement nowhere today, but if it ever does, the read is what the
  -- budget is about.
  assert_eq(
    'stats_bucket_mixed_prefers_normalized',
    bucket_of('INSERT INTO ophal_jobs(kind) SELECT title FROM content'),
    'normalized'
  )

  db_stats.reset()
  settings = {}
end

local function first_normalized_since(state, mark)
  for index = mark + 1, #state.queries do
    local sql = state.queries[index].sql

    for _, name in ipairs(db_stats.tables(sql)) do
      if not db_stats.is_projection_table(name) and not db_stats.is_infrastructure_table(name) then
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

-- Tag listing: the tag entity, the listing count, and the listing rows are all
-- payload-cached now, so this holds the same claim as the front page rather
-- than the weaker projection-only one it started with.
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
