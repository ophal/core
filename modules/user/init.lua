local json, crypto, tonumber = require 'dkjson', require 'crypto', tonumber
local print, exit, _SESSION, config = print, exit, env._SESSION, settings.user
local debug, error, empty, header = debug, error, seawolf.variable.empty, header
local theme, tconcat, add_js = theme, table.concat, add_js
local type, env, uuid, time, goto, pairs = type, env, uuid, os.time, goto, pairs
local session_destroy, module_invoke_all = session_destroy, module_invoke_all
local request_get_body = request_get_body

debug = debug

module 'ophal.modules.user'

--[[
  Implemens hook_menu().
]]
function menu()
  items = {}
  items['user/login'] = {
    title = 'User login',
    page_callback = 'login_page',
  }
  items['user/logout'] = {
    title = 'User logout',
    page_callback = 'logout_page',
  }
  items['user/auth'] = {
    title = 'User authentication web service',
    page_callback = 'auth_service',
    format = 'json',
  }
  items['user/token'] = {
    title = 'User token web service',
    page_callback = 'token_service',
    format = 'json',
  }
  return items
end

--[[
  Implements hook_init().
]]
function init()
  db_query = env.db_query

  -- Load user
  if _SESSION and _SESSION.user == nil then
    _SESSION.user = load{id = 0}
  end
end

function is_logged_in()
  if not empty(_SESSION.user) and not empty(_SESSION.user.id) then
    return not empty(_SESSION.user.id)
  end
end

function load(account)
  local rs

  if 'table' == type(account) then
    if account.id == 0 then
      account = {
        id = 0,
        name = 'Anonymous',
        role = 'anonymous',
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
    module_invoke_all('user_load', account)
    load_permissions(account)
  end

  return account
end

function load_permissions(account)
  if empty(config) then config = {} end
  if empty(config.role) then config.role = {} end
  if empty(config.user_role) then config.user_role = {} end

  local permissions = {}
  local user_roles = config.user_role
  local roles = config.role

  if empty(user_roles[0]) then user_roles[0] = {anonymous = true} end
  account.roles = user_roles[tonumber(account.id)] or {}
  account.permissions = {}
  for role, assigned in pairs(account.roles) do
    if assigned then
      for _, permission in pairs(roles[role] or {}) do
        permissions[permission] = true
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
      return account.permissions[perm]
    end
  end
  return false
end

function login_page()
  add_js 'libraries/jquery.min.js'
  add_js 'libraries/jquery.js'
  add_js 'libraries/jssha256.js'
  add_js 'modules/user/user_login.js'
  return tconcat{
    '<form method="POST">',
    '<table id="login_form" class="form">',
      '<tr><td>',
      theme.label{title = 'Username'},
      '</td><td>',
      theme.textfield{attributes = {id = 'login_user'}, value = ''},
      '</td></tr>',
      '<tr><td>',
      theme.label{title = 'Password'},
      '</td><td>',
      '<input id="login_pass" type="password" name="pass">',
      '</td></tr>',
      '<tr><td colspan="2" align="right">',
      theme.submit{attributes = {id = 'login_submit'}, value = 'Login'},
      '</td></tr>',
    '</table>',
    '</form>',
  }
end

function logout_page()
  if is_logged_in then
    session_destroy()
    goto ''
  end
end

function create()
  -- INSERT INTO user(name, mail, pass, active, created) values('User', 'user@example.com', 'password', 1, strftime('%s', 'now'));
end

function auth_service()
  local input, parsed, pos, err, account
  local output = {authenticated = false}

  input = request_get_body()
  parsed, pos, err = json.decode(input, 1, nil)

  if err then
    error(err)
  elseif
    'table' == type(_SESSION.user) and 'table' == type(_SESSION.user.token) and
    'table' == type(parsed) and not empty(parsed.user) and
    not empty(parsed.hash) and time() + 3 >= _SESSION.user.token.ts
  then
    account = load{name = parsed.user}
    if 'table' == type(account) and not empty(account.id) then
      if parsed.hash == crypto.hmac.digest('sha256', account.pass, _SESSION.user.token.id) then
        output.authenticated = true
        _SESSION.user = account
      end
    end
  end

  return output
end

function token_service()
  local output

  if _SESSION and  'table' == type(_SESSION.user) then
    _SESSION.user.token = {id = uuid.new(), ts = time()}
  end

  return _SESSION.user.token.id
end
