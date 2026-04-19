-- Unit tests for CSRF helpers and POST form token injection.

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

local function setup_security_env()
  _G.settings = {
    sessionapi = {enabled = true},
    slash = '/',
  }
  _G._SESSION = {}
  _G._GET = {}
  _G.uuid = {
    new = function() return 'csrf-token-1' end,
  }
  _G.seawolf = {
    variable = {
      empty = function(v)
        return v == nil or v == '' or v == 0 or v == false
      end,
    },
  }
  _G.header = function(k, v)
    _G.last_header = {k = k, v = v}
  end
  _G.last_header = nil

  dofile('includes/security.lua')
end

local function setup_form_env()
  _G.theme = {}
  setmetatable(theme, {
    __call = function(t, arg)
      return t[arg[1]](arg)
    end,
  })
  _G.module_invoke_all = function() end
  _G.render_attributes = function(options, default_options)
    options = options or {}
    if default_options then
      for k, v in pairs(default_options) do
        if options[k] == nil then
          options[k] = v
        end
      end
    end
    local output = {}
    for k, v in pairs(options) do
      output[#output + 1] = ('%s="%s"'):format(k, v)
    end
    table.sort(output)
    return table.concat(output, ' ')
  end

  dofile('includes/form.lua')
end

io.write '\n-- csrf helper --\n'

setup_security_env()
assert_eq('csrf_enabled_with_session', csrf_enabled(), true)
assert_eq('csrf_token_generated', csrf_token(), 'csrf-token-1')
assert_eq('csrf_token_reused', csrf_token(), 'csrf-token-1')
assert_eq('csrf_validate_token', csrf_validate('csrf-token-1'), true)
assert_eq('csrf_reject_missing', csrf_validate(nil), false)
assert_eq('csrf_validate_body_token', csrf_validate_request({csrf_token = 'csrf-token-1'}), true)
_GET.csrf_token = 'csrf-token-1'
assert_eq('csrf_validate_query_token', csrf_validate_request(), true)

local output = {}
_GET.csrf_token = 'bad'
assert_eq('csrf_denies_bad_query', csrf_validate_request(), false)
csrf_denied(output)
assert_eq('csrf_denied_status', last_header.v, 401)
assert_eq('csrf_denied_error', output.error, 'Invalid CSRF token.')

settings.csrf = false
assert_eq('csrf_disabled_accepts_missing', csrf_validate(nil), true)

io.write '\n-- csrf form injection --\n'

setup_security_env()
setup_form_env()

local post_form = theme{'form',
  method = 'POST',
  elements = {
    {'textfield', attributes = {id = 'title'}, value = 'Hello'},
  },
}
assert_match('post_form_method', post_form, 'method="POST"')
assert_match('post_form_csrf_name', post_form, 'name="csrf_token"')
assert_match('post_form_csrf_value', post_form, 'value="csrf%-token%-1"')

local get_form = theme{'form',
  method = 'GET',
  elements = {
    {'textfield', attributes = {id = 'title'}, value = 'Hello'},
  },
}
assert_eq('get_form_no_csrf', get_form:match('name="csrf_token"') == nil, true)

io.write(('\n%d passed, %d failed\n'):format(pass_count, fail_count))
if fail_count > 0 then
  os.exit(1)
end
