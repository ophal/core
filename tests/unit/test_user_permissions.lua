-- Unit tests for user role and permission delivery.

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

local function new_user_state()
  return {
    queries = {},
    users = {},
    roles = {},
    user_roles = {},
    role_permissions = {},
  }
end

local function make_db_query(state)
  return function(sql, ...)
    local args = {...}

    state.queries[#state.queries + 1] = {sql = sql, params = args}

    if sql:match('^SELECT %* FROM users WHERE') then
      local row = state.users[tonumber(args[1])]
      return rows_result(row and {row} or {})
    elseif sql:match('^SELECT id, name FROM role') then
      local rows = {}
      for _, role in ipairs(state.roles) do
        rows[#rows + 1] = {id = role.id, name = role.name}
      end
      return rows_result(rows)
    elseif sql:match('^SELECT ur%.role_id') then
      local rows = {}
      for _, rel in ipairs(state.user_roles) do
        if tonumber(rel.user_id) == tonumber(args[1]) then
          rows[#rows + 1] = {role_id = rel.role_id}
        end
      end
      return rows_result(rows)
    elseif sql:match('^SELECT permission') then
      local seen, rows = {}, {}
      for _, grant in ipairs(state.role_permissions) do
        if sql:find("'" .. grant.role_id .. "'", 1, true) and not seen[grant.permission] then
          seen[grant.permission] = true
          rows[#rows + 1] = {permission = grant.permission}
        end
      end
      return rows_result(rows)
    end

    return rows_result({})
  end
end

local function setup_user_env(state, session_user_id)
  _SESSION = {user_id = session_user_id}
  settings = {
    user = {
      permissions_storage = true,
      roles = {},
      user_role = {},
      permissions = {},
    },
  }
  ophal = {modules = {}}
  env = {
    _SESSION = _SESSION,
    db_query = make_db_query(state),
    db_field = function(_, field) return field end,
    db_last_insert_id = function() return 1 end,
  }
  header = function() end
  l = function(text) return text end
  theme = setmetatable({}, {__call = function() return '' end})
  add_js = function() end
  go_to = function() end
  session_destroy = function() end
  module_invoke_all = function() end
  request_get_body = function() return '' end
  route_execute_callback = function() end
  uuid = {new = function() return 'uuid' end}
  _GET, _SERVER = {}, {}

  package.loaded['ophal.modules.user'] = nil
  dofile('modules/user/init.lua')
  ophal.modules.user = package.loaded['ophal.modules.user']
  ophal.modules.user.init()
  return ophal.modules.user
end

io.write '\n-- authenticated permission budget --\n'

do
  local state = new_user_state()
  local user_mod
  local mark

  state.users[5] = {id = 5, name = 'author', status = 1}
  state.roles = {{id = 'editor', name = 'Editor'}}
  state.user_roles = {{user_id = 5, role_id = 'editor'}}
  state.role_permissions = {{role_id = 'editor', permission = 'edit own content'}}

  user_mod = setup_user_env(state, 5)

  assert_eq('perm_granted', user_mod.access('edit own content'), true)
  assert_eq('perm_denied', user_mod.access('administer users'), false)

  -- Four on a cold worker: the user row, the role list, this user's roles, and
  -- the permissions those roles grant. Warm, it is none of them -- permission
  -- delivery was already cache-first before this phase, which is why the work
  -- here is bounding and correctness rather than removing queries.
  assert_eq('perm_cold_queries', #state.queries, 4)

  mark = #state.queries
  user_mod.access('edit own content')
  user_mod.access('administer users')
  assert_eq('perm_warm_queries', #state.queries - mark, 0)
end

do
  local state = new_user_state()
  local user_mod
  local mark

  state.role_permissions = {{role_id = 'authenticated', permission = 'access content'}}

  -- The anonymous account is user 0, and it must not pick up the authenticated
  -- role now that the role no longer depends on the running session.
  user_mod = setup_user_env(state, 0)
  assert_eq('perm_anonymous_denied', user_mod.access('access content'), false)

  -- One query cold, for what the anonymous role grants. The roles themselves
  -- are seeded, and the account row for user 0 is built without a query.
  assert_eq('perm_anonymous_cold_queries', #state.queries, 1)

  mark = #state.queries
  user_mod.access('access content')
  assert_eq('perm_anonymous_warm_queries', #state.queries - mark, 0)
end

io.write '\n-- role cache and the session that warmed it --\n'

do
  local state = new_user_state()
  local user_mod

  state.users[1] = {id = 1, name = 'admin', status = 1}
  state.users[5] = {id = 5, name = 'author', status = 1}
  state.role_permissions = {{role_id = 'authenticated', permission = 'access content'}}

  -- Request one: an admin session asks about user 5. get_user_roles() decides
  -- authenticated versus anonymous by comparing against the *session* user, so
  -- this caches user 5 as anonymous.
  user_mod = setup_user_env(state, 1)
  user_mod.access('access content', 5)

  -- Request two: user 5's own session, same worker.
  _SESSION.user_id = 5
  assert_eq('roles_survive_foreign_session', user_mod.access('access content', 5), true)
end

io.write(('\n%d passed, %d failed\n'):format(pass_count, fail_count))

if fail_count > 0 then
  os.exit(1)
end
