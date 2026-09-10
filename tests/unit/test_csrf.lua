-- Unit tests for includes/security.lua: CSRF helpers, POST form token
-- injection, constant-time comparison, and the cron endpoint's token gate.

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
  --[[ The CSRF token comes from `includes/random.lua` now, not `uuid.new()`.

    Stubbed at the module rather than left to the real CSPRNG, so the token is
    a value these assertions can name. The stub has to be installed before
    `security.lua` is loaded, because that file captures the module in a local.
  ]]
  _G.uuid = {
    new = function() return 'csrf-token-1' end,
  }
  package.loaded['includes.random'] = {
    hex = function() return 'csrf-token-1' end,
    uuid = function() return 'csrf-token-1' end,
    bytes = function(n) return ('x'):rep(n) end,
    reset = function() end,
  }
  _G.header = function(k, v)
    _G.last_header = {k = k, v = v}
  end
  _G.request_body = ''
  _G.request_headers = {}
  _G.server_get_request = function()
    return {
      headers = _G.request_headers,
      body = _G.request_body,
    }
  end
  _G.request_get_body = function()
    return _G.request_body
  end
  _G.server_parse_query = function(query_string)
    local parsed = {}
    for item in (query_string or ''):gmatch('[^&]+') do
      local key, value = item:match('([^=]*)=?(.*)')
      parsed[key] = value
    end
    return parsed
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
assert_eq('csrf_reject_wrong', csrf_validate('csrf-token-2'), false)

--[[ Compared in constant time, like every other secret in this file.

  It was `==` until 2026-09-09, which returns at the first differing byte --
  the one secret comparison here not using the `secure_equals` sitting three
  functions above it. Pinned by identity rather than by timing: a timing
  assertion is flaky on a loaded machine, so this checks that the comparison
  used is the constant-time one by taking it away.
]]
do
  local real = secure_equals
  local saw

  _G.secure_equals = function(left, right)
    saw = {left = left, right = right}
    return real(left, right)
  end

  assert_eq('csrf_uses_constant_time_compare',
    csrf_validate('csrf-token-1'), true)
  assert_eq('csrf_compared_the_presented_token',
    saw and saw.left, 'csrf-token-1')
  assert_eq('csrf_compared_against_the_session',
    saw and saw.right, 'csrf-token-1')

  _G.secure_equals = real
end

-- An empty stored token must not be matchable. `secure_equals('', '')` is
-- true, so without the emptiness guard a session that has never issued a token
-- would accept one.
do
  local saved = _SESSION.csrf_token

  _SESSION.csrf_token = ''
  assert_eq('csrf_empty_session_token_matches_nothing', csrf_validate(''), false)
  _SESSION.csrf_token = saved
end
assert_eq('csrf_validate_body_token', csrf_validate_request({csrf_token = 'csrf-token-1'}), true)
request_headers = {['X-CSRF-Token'] = 'csrf-token-1'}
assert_eq('csrf_validate_header_token', csrf_validate_request(), true)
request_headers = {['Content-Type'] = 'application/x-www-form-urlencoded'}
request_body = 'csrf_token=csrf-token-1'
assert_eq('csrf_validate_form_body_token', csrf_validate_request(), true)
_GET.csrf_token = 'csrf-token-1'
assert_eq('csrf_validate_query_token', csrf_validate_request(), true)

local output = {}
_GET.csrf_token = 'bad'
request_headers = {}
request_body = ''
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

io.write '\n-- secure comparison --\n'

setup_security_env()

assert_eq('secure_equals_match', secure_equals('abc', 'abc'), true)
assert_eq('secure_equals_mismatch', secure_equals('abc', 'abd'), false)
assert_eq('secure_equals_length', secure_equals('abc', 'abcd'), false)
assert_eq('secure_equals_prefix', secure_equals('abcd', 'abc'), false)
assert_eq('secure_equals_empty', secure_equals('', ''), true)
assert_eq('secure_equals_nil', secure_equals(nil, ''), true)
assert_eq('secure_equals_nil_mismatch', secure_equals(nil, 'x'), false)
-- A byte-wise comparison that stopped at the first difference would still pass
-- every case above. This one pins the property that makes it constant-time:
-- the strings differ at their first byte and are long, so a short-circuiting
-- implementation returns without ever reading the rest.
assert_eq(
  'secure_equals_full_length_mismatch',
  secure_equals(('a'):rep(64), 'b' .. ('a'):rep(63)),
  false
)
-- The length term is not redundant with the byte loop, though every case above
-- passes without it: a byte past the end of the shorter string reads as 0, so
-- without the length check a value with a trailing NUL compares equal to the
-- same value without one. Lua strings are byte strings, and a hash or a token
-- arrives from a database column or a request header, so neither is guaranteed
-- NUL-free.
assert_eq('secure_equals_trailing_nul', secure_equals('abc\0', 'abc'), false)

io.write '\n-- cron token gate --\n'

-- The endpoint drains a queue of unbounded rebuilds, so who may ask for that
-- is a security question rather than an operational one.
do
  setup_security_env()
  settings.cron = {token = 'cron-secret'}

  _GET = {}
  request_headers = {}
  assert_eq('cron_denies_missing_token', cron_access(), false)

  _GET = {token = 'wrong'}
  assert_eq('cron_denies_wrong_token', cron_access(), false)

  _GET = {token = 'cron-secret'}
  assert_eq('cron_allows_query_token', cron_access(), true)

  _GET = {}
  request_headers = {['X-Ophal-Cron-Token'] = 'cron-secret'}
  assert_eq('cron_allows_header_token', cron_access(), true)

  request_headers = {['x-ophal-cron-token'] = 'cron-secret'}
  assert_eq('cron_header_case_insensitive', cron_access(), true)

  request_headers = {['X-Ophal-Cron-Token'] = 'wrong'}
  assert_eq('cron_denies_wrong_header', cron_access(), false)
end

-- An unconfigured token warns and allows, so upgrading a deployment does not
-- silently stop its scheduled work. The nginx `allow`/`deny` is what protects
-- this default, and the warning is what makes the gap visible.
do
  setup_security_env()
  _GET = {}
  request_headers = {}

  settings.cron = nil
  assert_eq('cron_allows_when_unconfigured', cron_access(), true)

  settings.cron = {token = ''}
  assert_eq('cron_allows_when_token_empty', cron_access(), true)

  settings.cron = {}
  assert_eq('cron_allows_when_token_absent', cron_access(), true)

  settings.cron = {token = 'cron-secret'}
  assert_eq('cron_token_reads_setting', cron_token(), 'cron-secret')
end

-- A refusal has to be a refusal the client can see, not a silent empty 200.
do
  setup_security_env()
  cron_denied()
  assert_eq('cron_denied_status', last_header and last_header.v, 403)
end

io.write '\n-- safe path segments --\n'

-- The upload endpoints interpolate a filename, an upload id and a chunk index
-- into filesystem paths, and `files/` is under the document root nginx serves
-- static extensions from. So the question this answers is not "is this tidy"
-- but "can a caller holding `upload files` write outside the directory the
-- permission is about".
do
  setup_security_env()

  assert_eq('segment_plain_name', safe_path_segment('report.pdf'), true)
  assert_eq('segment_hidden_file', safe_path_segment('.hidden'), true)
  assert_eq('segment_uuid', safe_path_segment('8f14e45f-ceea-467a-9f37-3e2b1c0d5a99'), true)
  assert_eq('segment_spaces_and_unicode', safe_path_segment('mi informe (final).pdf'), true)

  -- The traversal itself, in the shapes that reach a path.
  assert_eq('segment_parent', safe_path_segment('..'), false)
  assert_eq('segment_self', safe_path_segment('.'), false)
  assert_eq('segment_relative', safe_path_segment('../etc/passwd'), false)
  assert_eq('segment_absolute', safe_path_segment('/etc/passwd'), false)
  assert_eq('segment_nested', safe_path_segment('a/b'), false)
  assert_eq('segment_backslash', safe_path_segment('a\\b'), false)

  -- A NUL truncates the name the C library actually opens, so a value that
  -- reads as harmless in Lua can open a different, shorter path on disk.
  assert_eq('segment_nul', safe_path_segment('safe.txt\0/../../evil'), false)
  assert_eq('segment_newline', safe_path_segment('a\nb'), false)
  assert_eq('segment_tab', safe_path_segment('a\tb'), false)

  assert_eq('segment_empty', safe_path_segment(''), false)
  assert_eq('segment_nil', safe_path_segment(nil), false)
  assert_eq('segment_number', safe_path_segment(7), false)
  assert_eq('segment_too_long', safe_path_segment(('a'):rep(256)), false)
  assert_eq('segment_at_the_limit', safe_path_segment(('a'):rep(255)), true)
end

-- A refusal the client can see, and a 400 rather than a 401: the request was
-- authenticated and authorised, it just asked for something that is not a name.
do
  setup_security_env()
  local output = {}

  assert_eq('unsafe_path_returns_false', unsafe_path_denied(output, 'name'), false)
  assert_eq('unsafe_path_status', last_header and last_header.v, 400)
  assert_eq('unsafe_path_names_the_parameter', output.error, 'Invalid name.')
end

io.write(('\n%d passed, %d failed\n'):format(pass_count, fail_count))
if fail_count > 0 then
  os.exit(1)
end
