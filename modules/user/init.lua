local seawolf = require 'seawolf'.__build('other', 'variable', 'contrib')
local json, require, tonumber = require 'dkjson', require, tonumber

require 'modules.user.statements'
local print, exit, config = print, exit, settings.user or {}
local error, empty, header, l = error, seawolf.variable.empty, header, l
local theme, tconcat, add_js, unpack = theme, table.concat, add_js, unpack
local type, env, uuid, time, go_to, pairs, tostring = type, env, uuid, os.time, go_to, pairs, tostring
local session_destroy, module_invoke_all = session_destroy, module_invoke_all
local request_get_body, ophal, pcall = request_get_body, ophal, pcall
local route_execute_callback = route_execute_callback
local _SERVER = _SERVER
local xtable = seawolf.contrib.seawolf_table
local settings, floor = settings, math.floor
-- From `includes/security.lua`, which bootstrap requires before
-- `module_load_all()`. It is captured here, at load time, because `module()`
-- below replaces this file's environment with the module table, so a bare
-- global call would not resolve once the module is open.
local secure_equals = secure_equals

--[[ This request's session and query arguments.

  Read through `env` on every call rather than captured as locals at load time.
  `ophal_request_reset()` assigns a *new* table to each of them for every
  request -- `_GET` directly, `_SESSION` by way of `session_start()` -- so a
  capture taken when this file loaded keeps pointing at whatever the worker's
  first request carried.

  For `_SESSION` that was an authentication defect, not a stale-data one. This
  module is where a sign-in is recorded (`auth_service`) and where every later
  request is judged (`is_logged_in`, `current`, `access`), so a frozen table
  made all of them agree with each other and with nobody's actual session: one
  visitor signing in was read back as signed in by every later visitor the same
  worker served, `logout_page()` cleared a different table than the one being
  consulted, and the account never reached the session file at all. Invisible
  under `lua_code_cache off`, which reloads this file every request, and
  permanent under the `lua_code_cache on` that `nginx.ophal.conf` ships.

  `db_anonymous_whoami` in the smoke suite is the assertion that says so.
]]
local function session()
  return env._SESSION or {}
end

local function query_args()
  return env._GET or {}
end

module 'ophal.modules.user'

local db_connection
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

local function redirect_authority(target)
  if type(target) ~= 'string' or target == '' then
    return nil
  end

  return target:match('^[%w+%-%.]+://([^/%?#]+)') or target:match('^//([^/%?#]+)')
end

local function normalize_authority(authority)
  if type(authority) ~= 'string' or authority == '' then
    return nil
  end

  authority = authority:match('^[^@]*@(.+)$') or authority
  return authority:lower()
end

local function redirect_is_same_host(target)
  local request_host = normalize_authority(_SERVER 'HTTP_HOST')
  local target_host = normalize_authority(redirect_authority(target))

  return request_host ~= nil and target_host ~= nil and request_host == target_host
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
  local rs = db_connection():run('user.set_password', new_password_hash,
    account.id)

  account.pass = new_password_hash

  return rs
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
  -- Captured per request, not at load: a connection object belongs to the
  -- request that asked for it and raises at its next use once released.
  db_connection = env.db_connection

  -- Set anonymous user ID
  local current_session = session()

  if nil == current_session.user_id then
    current_session.user_id = 0
  end
end

function is_logged_in()
  return not empty(session().user_id)
end

function is_anonymous()
  return not is_logged_in()
end

-- The user object, role, and permission caches are all keyed by user id, and a
-- user id arrives with the session rather than from code. The number of
-- distinct keys a long-lived worker sees is therefore the number of accounts
-- that visit it, not a constant, which is the same unbounded-key-space problem
-- the projection payload cache has -- and these caches had no bound at all.
local DEFAULT_USER_CACHE_SIZE = 512

local function user_cache_limit()
  local performance = (settings or {}).performance or {}
  local size = tonumber(performance.user_cache_size)

  -- `size ~= size` is the NaN test.
  if size == nil or size ~= size or size < 0 then
    return DEFAULT_USER_CACHE_SIZE
  end

  return floor(size)
end

-- Two generations rather than a strict LRU. `set` fills `current`; when
-- `current` reaches the limit it becomes `previous` and a fresh one starts. A
-- key that is still being read is promoted back on its way through, so the
-- working set survives a rotation and only what nobody asked for is dropped.
-- Memory is bounded at twice the limit and the bookkeeping is one counter,
-- which is the right trade for entries this cheap to rebuild.
local function bounded_cache()
  local cache = {current = {}, previous = {}, count = 0}

  function cache:clear()
    self.current, self.previous, self.count = {}, {}, 0
  end

  function cache:set(key, value)
    local limit = user_cache_limit()

    -- A nil is not an entry: storing one would leave the key absent while the
    -- counter behaved as though it were present, and rotate early.
    if value == nil then
      self.current[key], self.previous[key] = nil, nil
      return nil
    end

    if limit < 1 then
      self:clear()
      return value
    end

    if self.current[key] == nil then
      self.count = self.count + 1
    end

    self.current[key] = value

    if self.count >= limit then
      self.previous, self.current, self.count = self.current, {}, 0
    end

    return value
  end

  function cache:get(key)
    local value = self.current[key]

    if value ~= nil then
      return value
    end

    value = self.previous[key]
    if value ~= nil then
      self:set(key, value)
    end

    return value
  end

  return cache
end

do
  local users = bounded_cache()

  --[[ Build user object for given user ID.
  ]]
  function load(user_id, reset)
    if user_id and empty(users:get(user_id)) or reset then
      users:set(user_id, load_by_field('id', user_id))
    end

    return users:get(user_id)
  end

  function users_cache_clear()
    users:clear()
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
    -- The column is part of the compile key, checked against the real schema
    -- once per distinct value per worker rather than formatted into SQL here.
    rs = db_connection():with('user.load_by_field', field):run(value)
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
        local rs = db_connection():run 'user.role_list'
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
  local users_roles = bounded_cache()

  users_roles:set(0, {anonymous = 'anonymous'})

  --[[ Return the list of roles assigned for given user ID.
  ]]
  function get_user_roles(user_id, reset)
    if nil == users_roles:get(user_id) or reset then
      if empty(config.user_role) then config.user_role = {} end

      local user_roles = {}
      local roles = get_roles()

      -- Add default authenticated role. Which of the two a user id gets is a
      -- property of the id -- 0 is the anonymous account, anything else is a
      -- real one -- and deliberately not a property of the running session.
      -- This compared against `_SESSION.user_id`, which made the answer depend
      -- on who was logged in when the worker first cached that id: a user
      -- warmed into the cache by somebody else's request was stored as
      -- anonymous and lost every `authenticated` permission until the worker
      -- restarted. Under CGI the cache died with the request and it never
      -- showed.
      if empty(user_id) then
        user_roles.anonymous = 'anonymous'
      else
        user_roles.authenticated = 'authenticated'
      end

      -- Traverse config.user_role to users_roles
      for _, role_id in pairs(config.user_role[user_id] or {}) do
        if roles[role_id] then
          user_roles[role_id] = role_id
        end
      end

      -- Load user <--> role relationships from database storage
      if config.permissions_storage then
        local rs = db_connection():run('user.roles', user_id)
        for row in rs:rows(true) do
          user_roles[row.role_id] = row.role_id
        end
      end

      users_roles:set(user_id, user_roles)
    end

    return users_roles:get(user_id)
  end

  function user_roles_cache_clear()
    users_roles:clear()
    users_roles:set(0, {anonymous = 'anonymous'})
  end
end

do
  local users_permissions = bounded_cache()

  --[[ Load user permissions from roles in provided account object.
  ]]
  function get_user_permissions(user_id, reset)
    if nil == users_permissions:get(user_id) or reset then
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

        --[[ Declared and variadic, reached with `db:list()`.

          This was assembled here until 2026-09-08 -- `IN ('%s')` over a
          concatenation of the role ids -- because a declared statement fixes
          its placeholder count at load time and this list is as wide as the
          account has roles. `?*` removed that reason. The ids came from
          `user_role` rather than from a request, which is why it stood, but it
          was the last value interpolation in the codebase and
          `tests/bench/injection_probe.lua` shows the shape returning a row from
          a WHERE clause written to match nothing on every backend.

          Every value is passed, gathered with `pairs` rather than over the
          array part. `roles:concat()` was seawolf's `table_concat`, which walks
          `pairs` and not `ipairs`, so it read the `anonymous` and
          `authenticated` markers -- string *keys* -- alongside the numeric role
          ids, and `role_permission` holds rows for both. Taking only
          `1 .. #roles` silently drops the markers and every permission that
          comes with one; `perm_granted` is what catches it.

          Runs once per role set per worker: `test_user_permissions.lua` pins
          the cold cost at four queries and the warm at zero.
        ]]
        local values = {}

        for _, role_id in pairs(roles) do
          values[#values + 1] = role_id
        end

        -- No roles means no rows to match. The layer refuses a zero-width list
        -- rather than rendering `IN ()`, which is a syntax error everywhere, so
        -- the empty case is answered here. `get_user_roles()` always returns at
        -- least one marker, so this guards a future shape rather than a live
        -- branch.
        if #values > 0 then
          local rs = db_connection():list('user.role_permissions', values)

          for row in rs:rows(true) do
            if nil == permissions[row.permission] then
              permissions[row.permission] = true
            end
          end
        end
      end

      users_permissions:set(user_id, permissions)
    end

    return users_permissions:get(user_id)
  end

  function user_permissions_cache_clear()
    users_permissions:clear()
  end
end

--[[ Clear all user-related caches (roles, user_roles, permissions).
]]
function cache_clear()
  roles_cache_clear()
  user_roles_cache_clear()
  user_permissions_cache_clear()
  users_cache_clear()
end

function access(perm, user_id)
  if nil == user_id then user_id = session().user_id end
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

  local db = db_connection()

  if entity.id then
    db:run('user.create_with_id',
      entity.id,
      entity.name,
      entity.mail,
      entity.pass,
      entity.active or false,
      entity.created or time()
    )
  else
    db:run('user.create',
      entity.name,
      entity.mail,
      entity.pass,
      entity.active or false,
      entity.created or time()
    )
    entity.id = db:last_insert_id('users', 'id')
  end

  module_invoke_all('entity_after_save', entity)

  return entity.id
end

function update(entity)
  local rs = db_connection():run('user.update',
    entity.name,
    entity.mail,
    entity.pass,
    entity.active,
    entity.created,
    entity.id
  )

  module_invoke_all('entity_after_save', entity)

  return rs
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

        --[[ A new session id before the account is written into it.

          The id that arrived on this request was chosen by whoever sent it --
          `session_init()` accepts any well-formed one from the cookie -- so
          carrying it into an authenticated session is fixation: plant an id on
          a visitor's browser, wait for them to sign in, and the planted id is
          now theirs. Rotating here is the standard defence, and it has to
          happen at the privilege change rather than at the next request.

          Before `user_login`'s hooks and before `user_id` is set, so anything
          a module writes into the session lands in the new one.
        ]]
        if type(session_regenerate) == 'function' then
          session_regenerate()
        end

        module_invoke_all('user_login', account, output)
        session().user_id = account.id

        local redirect_to = query_args().redirect

        if redirect_to and redirect_is_same_host(redirect_to) then
          output.redirect = redirect_to
        end
      end
    end
  end

  return output
end

--[[ Return the current user from _SESSION.
]]
function current()
  return load(session().user_id)
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
