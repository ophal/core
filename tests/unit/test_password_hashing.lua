-- Unit tests for password hashing upgrade path in modules/user/init.lua.

local json = require 'dkjson'

local pass_count, fail_count = 0, 0
local legacy_secret_sha256 = '2bb80d537b1da3e38bd30361aa855686bde0eacd7162fef6a25fe97bf527a25b'

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

local db_log, hook_log, request_body, selected_account
local uuid_counter = 0

local function mock_db_query(sql, ...)
  local params = {...}
  db_log[#db_log + 1] = {sql = sql, params = params}

  if sql:match('^SELECT %* FROM users') then
    return {
      fetch = function()
        return selected_account
      end,
      rows = function()
        return function() return nil end
      end,
    }
  end

  return {
    fetch = function() return nil end,
    rows = function()
      return function() return nil end
    end,
  }, nil
end

local function load_user_module()
  uuid_counter = 0
  db_log = {}
  hook_log = {}
  request_body = nil
  selected_account = nil

  package.loaded['ophal.modules.user'] = nil

  settings = {
    user = {
      password_hash = {
        iterations = 3,
      },
    },
  }

  env = {
    _SESSION = {},
    db_query = mock_db_query,
    db_field = function(_, field) return field end,
    db_last_insert_id = function() return 1 end,
  }
  _SESSION = env._SESSION
  _GET = {}
  _SERVER = function(key)
    if key == 'HTTP_HOST' then
      return 'example.com'
    end
  end
  socket = {
    url = {
      parse = function(target)
        return {
          host = target and target:match('^https?://([^/]+)') or nil,
        }
      end,
    },
  }
  uuid = {
    new = function()
      uuid_counter = uuid_counter + 1
      return ('00000000-0000-0000-0000-%012d'):format(uuid_counter)
    end,
  }
  ophal = {modules = {}}
  header = function() end
  l = function(text) return text end
  theme = setmetatable({}, {__call = function() return '' end})
  add_js = function() end
  go_to = function() end
  session_destroy = function() end
  request_get_body = function()
    return request_body
  end
  route_execute_callback = function(handler, callback_name)
    local callback = handler and handler[callback_name]
    if type(callback) == 'function' then
      return true, callback()
    end
    return true, nil
  end
  module_invoke_all = function(hook, ...)
    hook_log[#hook_log + 1] = {hook = hook, args = {...}}
  end

  dofile('modules/user/init.lua')
  ophal.modules.user.init()

  return ophal.modules.user
end

io.write '\n-- password helpers --\n'

do
  local user = load_user_module()
  local upgraded, needs_rehash = user.password_verify('secret', legacy_secret_sha256)
  local rejected, rejected_needs_rehash = user.password_verify('wrong', legacy_secret_sha256)

  assert_eq('legacy_password_verify', upgraded, true)
  assert_eq('legacy_password_needs_rehash', needs_rehash, true)
  assert_eq('legacy_password_rejects_bad_secret', rejected, false)
  assert_eq('legacy_password_bad_secret_no_rehash', rejected_needs_rehash, false)
end

do
  local user = load_user_module()
  settings.user.password_hash.iterations = 2

  local stored = user.password_hash('secret', {salt = 'fixedsalt'})
  local upgraded, needs_rehash = user.password_verify('secret', stored)

  assert_match('versioned_hash_format', stored, '^ophal%$1%$sha256%$2%$fixedsalt%$[0-9a-f]+$')
  assert_eq('versioned_password_verify', upgraded, true)
  assert_eq('versioned_password_current_policy', needs_rehash, false)

  settings.user.password_hash.iterations = 3
  assert_eq('versioned_password_needs_rehash_after_policy_change', user.password_needs_rehash(stored), true)
end

io.write '\n-- auth service upgrade path --\n'

do
  local user = load_user_module()

  selected_account = {
    id = 7,
    name = 'alice',
    mail = 'alice@example.com',
    pass = legacy_secret_sha256,
  }
  request_body = json.encode({user = 'alice', pass = 'secret'})

  local output = user.auth_service()

  assert_eq('legacy_login_authenticated', output.authenticated, true)
  assert_eq('legacy_login_sets_session', env._SESSION.user_id, 7)
  assert_eq('legacy_login_query_count', #db_log, 2)
  assert_match('legacy_login_rehash_query', db_log[2].sql, '^UPDATE users SET pass = %? WHERE id = %?$')
  assert_match('legacy_login_rehash_value', db_log[2].params[1], '^ophal%$1%$sha256%$3%$')
  assert_eq('legacy_login_rehash_target_user', db_log[2].params[2], 7)
  assert_eq('legacy_login_account_updated', selected_account.pass == db_log[2].params[1], true)
  assert_eq('legacy_login_user_hook', hook_log[#hook_log].hook, 'user_login')
end

do
  local user = load_user_module()

  selected_account = {
    id = 8,
    name = 'bob',
    mail = 'bob@example.com',
    pass = user.password_hash('secret', {salt = 'freshsalt'}),
  }
  request_body = json.encode({user = 'bob', pass = 'secret'})

  local output = user.auth_service()

  assert_eq('current_hash_login_authenticated', output.authenticated, true)
  assert_eq('current_hash_login_query_count', #db_log, 1)
end

io.write(('\n%d passed, %d failed\n'):format(pass_count, fail_count))
if fail_count > 0 then
  os.exit(1)
end
