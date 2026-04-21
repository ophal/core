local seawolf = require 'seawolf'.__build('other', 'variable', 'contrib')
local json, require, tonumber = require 'dkjson', require, tonumber
local print, exit, _SESSION, config = print, exit, env._SESSION, settings.user or {}
local error, empty, header, l = error, seawolf.variable.empty, header, l
local theme, tconcat, add_js, unpack = theme, table.concat, add_js, unpack
local type, env, uuid, time, go_to, pairs, tostring = type, env, uuid, os.time, go_to, pairs, tostring
local session_destroy, module_invoke_all = session_destroy, module_invoke_all
local request_get_body, ophal, pcall = request_get_body, ophal, pcall
local route_execute_callback, _GET = route_execute_callback, _GET
local url_parse, _SERVER = socket.url.parse, _SERVER
local xtable = seawolf.contrib.seawolf_table

module 'ophal.modules.user'

local db_query, db_field, db_last_insert_id
local password_hash_prefix = 'ophal$1$'
local hash

do
  local digest_modules = {}

  local function load_digest_module(name)
    if digest_modules[name] == nil then
      local ok, module_impl = pcall(require, name)
      digest_modules[name] = ok and module_impl or false
    end

    return digest_modules[name] or nil
  end

  local function fallback_hash(algo, data, raw_output)
    local digest

    if raw_output then
      error(('[user] raw hash output is unsupported for algorithm "%s"'):format(algo))
    end

    if algo == 'md5' then
      local md5 = load_digest_module('md5')
      digest = md5 and md5.sumhexa
    elseif algo == 'sha1' then
      local sha1 = load_digest_module('sha1')
      digest = sha1 and sha1.sha1
    elseif algo == 'sha224' then
      local lsha2 = load_digest_module('lsha2')
      digest = lsha2 and lsha2.hash224
    elseif algo == 'sha256' then
      local lsha2 = load_digest_module('lsha2')
      local sha2 = load_digest_module('sha2')
      local sha256 = load_digest_module('includes.sha256')
      digest = lsha2 and lsha2.hash256 or sha2 and sha2.sha256hex or sha256 and sha256.hash256
    elseif algo == 'sha384' then
      local sha2 = load_digest_module('sha2')
      digest = sha2 and sha2.sha384hex
    elseif algo == 'sha512' then
      local sha2 = load_digest_module('sha2')
      digest = sha2 and sha2.sha512hex
    end

    if nil == digest then
      error(('[user] unknown hash algorithm "%s"'):format(algo))
    end

    return digest(data)
  end

  hash = seawolf.other and type(seawolf.other.hash) == 'function' and seawolf.other.hash or fallback_hash
end

local function secure_equals(left, right)
  local max_len, mismatch
  left, right = tostring(left or ''), tostring(right or '')
  max_len = #left
  mismatch = #left == #right and 0 or 1

  if #right > max_len then
    max_len = #right
  end

  for i = 1, max_len do
    if (left:byte(i) or 0) ~= (right:byte(i) or 0) then
      mismatch = mismatch + 1
    end
  end

  return mismatch == 0
end

local function password_hash_config()
  local hash_config = config.password_hash or {}
  local algorithm = hash_config.algorithm or 'sha256'
  local iterations = tonumber(hash_config.iterations) or 10000

  if iterations < 1 then
    iterations = 1
  end

  return {
    algorithm = algorithm,
    iterations = iterations,
  }
end

local function password_legacy_hash(password)
  return hash(config.algorithm or 'sha256', password or '')
end

local function password_hash_parse(stored_password)
  local version, algorithm, iterations, salt, digest

  if type(stored_password) ~= 'string' then
    return nil
  end

  version, algorithm, iterations, salt, digest = stored_password:match(
    '^ophal%$(%d+)%$([^$]+)%$(%d+)%$([^$]+)%$([0-9a-fA-F]+)$'
  )

  if version == '1' then
    return {
      version = 1,
      algorithm = algorithm,
      iterations = tonumber(iterations) or 1,
      salt = salt,
      digest = digest:lower(),
    }
  end

  return nil
end

local function password_digest(password, options)
  local digest = hash(options.algorithm, ('%s$%s'):format(options.salt, password or ''))

  for _ = 2, options.iterations do
    digest = hash(options.algorithm, ('%s$%s$%s'):format(digest, options.salt, password or ''))
  end

  return digest
end

local function password_rehash_account(account, password)
  local new_password_hash = password_hash(password)
  local rs, err = db_query('UPDATE users SET pass = ? WHERE id = ?', new_password_hash, account.id)

  if not err then
    account.pass = new_password_hash
  end

  return rs, err
end

function password_hash(password, options)
  local hash_options = password_hash_config()

  if type(options) == 'table' then
    hash_options = {
      algorithm = options.algorithm or hash_options.algorithm,
      iterations = tonumber(options.iterations) or hash_options.iterations,
      salt = options.salt,
    }
  end

  if hash_options.iterations < 1 then
    hash_options.iterations = 1
  end

  if empty(hash_options.salt) then
    hash_options.salt = (uuid.new() or ''):gsub('%-', '')
  end

  return ('%s%s$%d$%s$%s'):format(
    password_hash_prefix,
    hash_options.algorithm,
    hash_options.iterations,
    hash_options.salt,
    password_digest(password, hash_options)
  )
end

function password_needs_rehash(stored_password)
  local parsed = password_hash_parse(stored_password)
  local hash_options = password_hash_config()

  if nil == parsed then
    return true
  end

  return parsed.algorithm ~= hash_options.algorithm or
    parsed.iterations ~= hash_options.iterations
end

function password_verify(password, stored_password)
  local parsed = password_hash_parse(stored_password)
  local verified

  if parsed then
    verified = secure_equals(stored_password, password_hash(password, parsed))
    return verified, verified and password_needs_rehash(stored_password)
  end

  verified = secure_equals(stored_password, password_legacy_hash(password))
  return verified, verified
end

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
  db_field = env.db_field
  db_last_insert_id = env.db_last_insert_id

  -- Set anonymous user ID
  if nil == _SESSION.user_id then
    _SESSION.user_id = 0
  end
end

function is_logged_in()
  return not empty(_SESSION.user_id)
end

function is_anonymous()
  return not is_logged_in()
end

do
  local users = {}

  --[[ Build user object for given user ID.
  ]]
  function load(user_id, reset)
    if user_id and empty(users[user_id]) or reset then
      users[user_id] = load_by_field('id', user_id)
    end

    return users[user_id]
  end
end

function load_by_field(field, value)
  local rs, entity

  if field == 'id' and value == 0 then
    entity = {
      id = 0,
      name = 'Anonymous',
    }
  elseif not empty(field) and not empty(value) then
    local sql = ('SELECT * FROM users WHERE %s = ?'):format(db_field('users', field))
    rs = db_query(sql, value)
    entity = rs:fetch(true)
  end

  if not empty(entity) then
    entity.type = 'user'
    module_invoke_all('entity_load', entity)
  end

  return entity
end

--[[ Return the list of configured roles.
]]
do
  local roles

  function get_roles(reset)
    if nil == config.roles then config.roles = {} end

    if nil == roles or reset then
      -- Default roles
      roles = {
        anonymous = 'Anonymous',
        authenticated = 'Authenticated',
      }

      -- Load roles from settings
      for id, name in pairs(config.roles) do
        roles[id] = name
      end

      -- Load roles from database storage
      if config.permissions_storage then
        local rs, err = db_query [[SELECT id, name FROM role WHERE active = 1 ORDER BY weight, id]]
        for role in rs:rows(true) do
          roles[role.id] = role.name
        end
      end
    end

    return roles
  end

  function roles_cache_clear()
    roles = nil
  end
end

do
  local users_roles = {
    [0] = {anonymous = 'anonymous'},
  }

  --[[ Return the list of roles assigned for given user ID.
  ]]
  function get_user_roles(user_id, reset)
    if nil == users_roles[user_id] or reset then
      if empty(config.user_role) then config.user_role = {} end

      local user_roles = {}
      local roles = get_roles()

      -- Add default authenticated role
      if _SESSION.user_id == user_id then
        user_roles.authenticated = 'authenticated'
      else
        user_roles.anonymous = 'anonymous'
      end

      -- Traverse config.user_role to users_roles
      for _, role_id in pairs(config.user_role[user_id] or {}) do
        if roles[role_id] then
          user_roles[role_id] = role_id
        end
      end

      -- Load user <--> role relationships from database storage
      if config.permissions_storage then
        local rs, err = db_query([[
SELECT ur.role_id
FROM user_role ur JOIN role r ON ur.role_id = r.id
WHERE user_id = ?]], user_id)
        for row in rs:rows(true) do
          user_roles[row.role_id] = row.role_id
        end
      end

      users_roles[user_id] = user_roles
    end

    return users_roles[user_id]
  end

  function user_roles_cache_clear()
    users_roles = {[0] = {anonymous = 'anonymous'}}
  end
end

do
  local users_permissions = {}

  --[[ Load user permissions from roles in provided account object.
  ]]
  function get_user_permissions(user_id, reset)
    if nil == users_permissions[user_id] or reset then
      local permissions = {}
      local user_roles = get_user_roles(user_id)
      if nil == config.permissions then config.permissions = {} end

      -- Load permissions from settings
      for role_id, assigned in pairs(user_roles or {}) do
        for _, perm in pairs(config.permissions[role_id] or {}) do
          permissions[perm] = true
        end
      end

      -- Load permissions from database storage
      if config.permissions_storage then
        local roles = xtable(get_user_roles(user_id) or {})

        local rs, err = db_query([[
SELECT permission
FROM role_permission
WHERE role_id IN (']] .. roles:concat("', '") .. [[')
GROUP BY permission
ORDER BY permission
]])
        for row in rs:rows(true) do
          if nil == permissions[row.permission] then
            permissions[row.permission] = true
          end
        end
      end

      users_permissions[user_id] = permissions
    end

    return users_permissions[user_id]
  end

  function user_permissions_cache_clear()
    users_permissions = {}
  end
end

--[[ Clear all user-related caches (roles, user_roles, permissions).
]]
function cache_clear()
  roles_cache_clear()
  user_roles_cache_clear()
  user_permissions_cache_clear()
end

function access(perm, user_id)
  if nil == user_id then user_id = _SESSION.user_id end
  local account = load(user_id)

  local permissions = get_user_permissions(user_id)

  if tonumber(user_id) == 1 then
    return true
  elseif not empty(permissions) then
    return permissions[perm] or false
  end

  return false
end

function default_page()
  if not is_logged_in() then
    go_to 'user/login'
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
    go_to ''
  end
end

function create(entity)
  local rs, err

  if entity.type == nil then entity.type = 'user' end

  if entity.id then
    rs, err = db_query([[
INSERT INTO users(id, name, mail, pass, active, created)
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
INSERT INTO users(name, mail, pass, active, created)
VALUES(?, ?, ?, ?, ?)]],
      entity.name,
      entity.mail,
      entity.pass,
      entity.active or false,
      entity.created or time()
    )
    entity.id = db_last_insert_id('users', 'id')
  end

  if not err then
    module_invoke_all('entity_after_save', entity)
  end
  return entity.id, err
end

function update(entity)
  local rs, err
  rs, err = db_query('UPDATE users SET name = ?, mail = ?, pass = ?, active = ?, created = ? WHERE id = ?',
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
  local input, parsed, pos, err, account, authenticated, needs_rehash
  local output = {authenticated = false}

  input = request_get_body()

  if input == nil then
    output.authenticated = is_logged_in()
    return output
  end

  parsed, pos, err = json.decode(input, 1, nil)

  if err then
    error(err)
  elseif
    'table' == type(parsed) and not empty(parsed.user) and
    not empty(parsed.pass)
  then
    account = load_by_field('name', parsed.user)
    if 'table' == type(account) and not empty(account.id) then
      authenticated, needs_rehash = password_verify(parsed.pass or '', account.pass)

      if authenticated then
        output.authenticated = true

        if needs_rehash then
          password_rehash_account(account, parsed.pass or '')
        end

        module_invoke_all('user_login', account, output)
        _SESSION.user_id = account.id

        if _GET.redirect and url_parse(_GET.redirect).host == _SERVER 'HTTP_HOST' then
          output.redirect = _GET.redirect
        end
      end
    end
  end

  return output
end

--[[ Return the current user from _SESSION.
]]
function current()
  return load(_SESSION.user_id)
end

--[[ Render author.
]]
function theme.author(variables)
  local entity = variables.entity or {}
  local account = load(entity.user_id)

  if empty(account.id) then
    return account.name
  else
    return l(account.name, 'user/' .. account.id)
  end
end
