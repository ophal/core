local seawolf = require 'seawolf'.__build('other', 'variable')
local json, hash, tonumber = require 'dkjson', seawolf.other.hash, tonumber
local print, exit, _SESSION, config = print, exit, env._SESSION, settings.user
local error, empty, header = error, seawolf.variable.empty, header
local theme, tconcat, add_js, unpack = theme, table.concat, add_js, unpack
local type, env, uuid, time, goto, pairs = type, env, uuid, os.time, goto, pairs
local session_destroy, module_invoke_all = session_destroy, module_invoke_all
local request_get_body, ophal, pcall = request_get_body, ophal, pcall
local route_execute_callback = route_execute_callback

module 'ophal.modules.user'

--[[ Implements hook route().
]]
function route()
  items = {}
  items.user = {
    page_callback = 'default_page'
  }
  items['user/login'] = {
    title = 'User login',
    page_callback = 'login_page',
    access_callback = 'is_anonymous',
  }
  items['user/logout'] = {
    title = 'User logout',
    page_callback = 'logout_page',
    access_callback = 'is_logged_in',
  }
  items['user/auth'] = {
    title = 'User authentication web service',
    page_callback = 'auth_service',
    format = 'json',
  }
  return items
end

--[[ Implements hook route_validate_handler().

  NOTE: the access_callback should return false (not just nil) in order to raise
        a '401 Access Denied'.
]]
function route_validate_handler(handler)
  local status, result

  status, result = route_execute_callback(handler, 'access_callback')

  if not status then
    handler.error = 500
    handler.title = 'Unexpected error'
    handler.content = ("module '%s': %s"):format(handler.module, result or '')
  elseif result == false then
    handler.error = 401
    handler.title = 'Access denied'
    handler.content = handler.title
  end
end

--[[ Implements hook init().
]]
function init()
  db_query = env.db_query
  db_last_insert_id = env.db_last_insert_id

  -- Load user
  if _SESSION and _SESSION.user == nil then
    _SESSION.user = load{id = 0}
  end
end

function is_logged_in()
  if not empty(_SESSION.user) and not empty(_SESSION.user.id) then
    return not empty(_SESSION.user.id)
  end
  -- No session or user is anonymous
  return false
end

function is_anonymous()
  return not is_logged_in()
end

function load(account)
  local rs

  if 'table' == type(account) then
    if account.id == 0 then
      account = {
        id = 0,
        name = 'Anonymous',
      }
    elseif not empty(account.id) then
      rs = db_query('SELECT * FROM user WHERE id = ?', account.id)
      account = rs:fetch(true)
    elseif not empty(account.name) then
      rs = db_query('SELECT * FROM user WHERE name = ?', account.name)
      account = rs:fetch(true)
    end
  end

  if not empty(account) then
    account.type = 'user'
    module_invoke_all('user_load', account)
    load_permissions(account)
  end

  return account
end

do
  local roles_permissions
  local roles_permissions_cached
  function load_roles_permissions(config, force_reload)
    if config.role == nil then config.role = {} end

    -- Return cached roles_permissions
    if roles_permissions_cached and not force_reload then
      return roles_permissions
    end

    roles_permissions = {}

    -- Traverse config.role to roles_permissions
    for role_id, permissions in pairs(config.role) do
      local buffer = {}
      for _, perm in pairs(permissions) do
        buffer[perm] = true
      end
      roles_permissions[role_id] = buffer
    end

    -- Load permissions from database storage
    if config.permissions_storage then
      local rs, err = db_query [[
SELECT rp.*
FROM
  role_permission AS rp LEFT JOIN
  role AS r ON r.id = rp.role_id AND r.active = 1
ORDER BY rp.role_id, rp.permission
  ]]
      for row in rs:rows(true) do
        if roles_permissions[row.role_id] == nil then
          roles_permissions[row.role_id] = {}
        end

        -- Do not override config from settings.lua
        if roles_permissions[row.role_id][row.permission] == nil then
          roles_permissions[row.role_id][row.permission] = true
        end
      end
    end

    roles_permissions_cached = true

    return roles_permissions
  end
end

do
  local users_roles = {
    [0] = {anonymous = true},
  }
  local users_roles_cached
  function load_users_roles(settings, force_reload)
    if empty(config.user_role) then config.user_role = {} end

    -- Return cached users_roles
    if users_roles_cached and not force_reload then
      return users_roles
    end

    -- Traverse config.user_role to users_roles
    for user_id, roles in pairs(config.user_role) do
      local buffer = {}
      for _, role_id in pairs(permissions) do
        buffer[role_id] = true
      end
      users_roles[user_id] = buffer
    end

    -- Load user <--> role relationships from database storage
    if config.permissions_storage then
      local rs, err = db_query 'SELECT * FROM user_role'
      for row in rs:rows(true) do
        local user_id = tonumber(row.user_id)
        if users_roles[user_id] == nil then
          users_roles[user_id] = {}
        end

        -- Do not override config from settings.lua
        if users_roles[user_id][row.role_id] == nil then
          users_roles[user_id][row.role_id] = true
        end
      end
    end

    users_roles_cached = true

    return users_roles
  end
end

function load_permissions(account, force_reload)
  if empty(config) then config = {} end
  if empty(config.role) then config.role = {} end
  if empty(config.user_role) then config.user_role = {} end

  local roles_permissions = load_roles_permissions(config)
  local users_roles = load_users_roles(config)
  local permissions = {}
  local roles = config.role

  account.roles = users_roles[tonumber(account.id)] or {}
  account.permissions = {}
  for role, assigned in pairs(account.roles) do
    if assigned then
      for permission, granted in pairs(roles_permissions[role] or {}) do
        if granted then
          permissions[permission] = true
        end
      end
    end
  end

  account.permissions = permissions
end

function access(perm)
  local account

  if _SESSION and not empty(_SESSION.user) then
    account = _SESSION.user
    if tonumber(account.id) == 1 then
      return true
    elseif not empty(account.permissions) then
      return account.permissions[perm] or false
    end
  end
  return false
end

function default_page()
  if not is_logged_in() then
    goto 'user/login'
  end
end

function login_page()
  add_js 'libraries/jquery.min.js'
  add_js 'modules/user/user_login.js'

  return theme{'form', attributes = {id = 'login_form'},
    elements = {
      {'textfield', title = 'Username', value = '', attributes = {id = 'login_user'}},
      {'textfield', title = 'Password', value = '', attributes = {id = 'login_pass', type = 'password'}},
      {'submit', value = 'Login', attributes = {id = 'login_submit'}},
    },
  }
end

function logout_page()
  if is_logged_in then
    session_destroy()
    goto ''
  end
end

function create(entity)
  local rs, err

  if entity.type == nil then entity.type = 'user' end

  if entity.id then
    rs, err = db_query([[
INSERT INTO user(id, name, mail, pass, active, created)
VALUES(?, ?, ?, ?, ?, ?)]],
      entity.id,
      entity.name,
      entity.mail,
      entity.pass,
      entity.active or false,
      entity.created or time()
    )
  else
    rs, err = db_query([[
INSERT INTO user(name, mail, pass, active, created)
VALUES(?, ?, ?, ?, ?)]],
      entity.name,
      entity.mail,
      entity.pass,
      entity.active or false,
      entity.created or time()
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
  rs, err = db_query('UPDATE content SET name = ?, mail = ?, pass = ?, active = ?, created = ? WHERE id = ?',
    entity.name,
    entity.mail,
    entity.pass,
    entity.active,
    entity.created,
    entity.id
  )
  if not err then
    module_invoke_all('entity_after_save', entity)
  end
  return rs, err
end


function auth_service()
  local input, parsed, pos, err, account
  local output = {authenticated = false}

  input = request_get_body()
  parsed, pos, err = json.decode(input, 1, nil)

  if err then
    error(err)
  elseif
    'table' == type(parsed) and not empty(parsed.user) and
    not empty(parsed.pass)
  then
    account = load{name = parsed.user}
    if 'table' == type(account) and not empty(account.id) then
      if account.pass == hash(config.algorithm or 'sha256', parsed.pass or '') then
        output.authenticated = true
        _SESSION.user = account
      end
    end
  end

  return output
end

--[[ Return the current user from _SESSION.
]]
function current()
  if _SESSION then
    return _SESSION.user
  end
end
