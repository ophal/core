--[[ Output escaping: what reaches HTML, and what has to be escaped first.

  These exist because `modules/file` rendered `entity.filename` raw into two
  theme functions, and a filename is attacker-chosen -- it arrives as `?name=`
  on `file/merge`. The only guard on it is `safe_path_segment()`, which is a
  *path* check: it rejects separators, NUL and control bytes, and has no opinion
  about `<` or `"`, correctly, because those are legal in a filename. So
  `<img src=x onerror=alert(1)>` was a valid filename by that rule and ran for
  every viewer of the file field.

  The first assertions here are the ones that make that a contradiction rather
  than a judgement call: the payloads a path guard accepts, and the escaping the
  themes must apply to them anyway.
]]

package.path = './?.lua;./?/init.lua;' .. package.path

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

local function assert_absent(label, haystack, needle)
  if tostring(haystack):find(needle, 1, true) then
    fail_count = fail_count + 1
    io.write(('  FAIL %s: %q appeared in the output\n'):format(label, needle))
  else
    pass_count = pass_count + 1
    io.write(('  ok %s\n'):format(label))
  end
end

local function assert_present(label, haystack, needle)
  if tostring(haystack):find(needle, 1, true) then
    pass_count = pass_count + 1
    io.write(('  ok %s\n'):format(label))
  else
    fail_count = fail_count + 1
    io.write(('  FAIL %s: %q missing from the output\n'):format(label, needle))
  end
end

-- The payload used throughout: no `/` and no `\`, so it is a legal path
-- segment, and unmistakably script if it reaches HTML unescaped.
local XSS = '<img src=x onerror=alert(1)>'

_G.settings = {sessionapi = {enabled = true}, file = {}, site = {files_path = '/tmp'}}
_G.header = function() end
package.loaded['includes.random'] = {
  hex = function() return 'token' end,
  uuid = function() return 'token' end,
  bytes = function(n) return ('x'):rep(n) end,
  reset = function() end,
}

dofile('includes/escape.lua')
dofile('includes/security.lua')

io.write '\n-- a path guard is not an HTML guard --\n'

--[[ The contradiction, stated as two assertions side by side.

  Both are correct: `safe_path_segment` is about traversal and `html_escape` is
  about markup. Putting them next to each other is what says a value can pass
  one and still be unsafe for the other, which is the reasoning that was
  missing where the filename was rendered.
]]
assert_eq('path_guard_accepts_markup', safe_path_segment(XSS), true)
assert_eq('path_guard_accepts_quotes', safe_path_segment('" onmouseover="x'), true)
assert_eq('path_guard_still_refuses_traversal', safe_path_segment('../etc'), false)

io.write '\n-- html_escape --\n'

assert_absent('escape_removes_open_bracket', html_escape(XSS), '<')
assert_absent('escape_removes_close_bracket', html_escape(XSS), '>')
assert_present('escape_keeps_the_text', html_escape(XSS), '&lt;img')
assert_eq('escape_ampersand_first', html_escape('&lt;'), '&amp;lt;')

-- Attribute context needs the quote characters too, or a value closes the
-- attribute it sits in and starts a new one.
assert_absent('attr_escape_removes_double_quote', html_attr_escape('" onx="'), '"')
assert_absent('attr_escape_removes_single_quote', html_attr_escape("' onx='"), "'")
assert_absent('attr_escape_removes_newline', html_attr_escape('a\nb'), '\n')

io.write '\n-- the file themes --\n'

--[[ Driven through the real theme functions rather than asserted about the
  source, so a future rewrite that reintroduces raw output fails here.
]]
do
  _G.ophal = {modules = {}, title = nil}
  _G.add_js = function() end
  -- Stubbed *before* the module is loaded: `modules/file` captures
  -- `render_attributes` at load time, so replacing the global afterwards leaves
  -- the module holding the original. Same rule the module itself documents.
  _G.render_attributes = function(attrs)
    return attrs and 'data-x="1"' or ''
  end
  _G.format_size = function(v) return tostring(v or 0) end
  _G.format_date = function(v) return tostring(v or 0) end
  _G.theme = setmetatable({}, {__call = function(_, spec)
    return '[' .. tostring(type(spec) == 'table' and spec[1] or spec) .. ']'
  end})
  _G.module_invoke_all = function() end
  _G.request_get_body = function() return nil end
  _G.request_get_body_file = function() return nil end
  _G.csrf_validate_request = function() return true end
  _G.csrf_denied = function() return false end
  _G.l = function(text) return tostring(text) end
  _G.t = function(v) return v end
  _G.lfs = {attributes = function() return nil end}
  _G.env = {}

  dofile('modules/file/init.lua')

  local file_module = package.loaded['ophal.modules.file']
  local themes = file_module and file_module.theme or _G.theme

  local field = themes.file{id = 'f1', entity = {id = 7, filename = XSS, timestamp = 0}}
  assert_absent('theme_file_escapes_the_filename', field, XSS)
  assert_present('theme_file_shows_the_escaped_name', field, '&lt;img')

  --[[ The upload input carried one `%s` and three arguments, so `format` put
    `id` in the slot and threw the rest away -- the markup was
    `<input upload type="file">` and the caller's attributes were silently
    dropped. `file.js` selects on the class, so nothing looked wrong.
  ]]
  assert_present('theme_file_input_has_an_id', field, 'id="f1_file"')
  assert_absent('theme_file_input_has_no_bare_attribute', field, '<input f1 ')
  assert_present('theme_file_input_keeps_its_class', field, 'form-upload-file')

  local with_attrs = themes.file{
    id = 'f2',
    entity = {},
    attributes = {['data-x'] = '1'},
  }

  assert_present('theme_file_renders_caller_attributes', with_attrs, 'data-x="1"')

  local info = themes.file_info{file = {filename = XSS, filesize = 1, timestamp = 0}}
  assert_absent('theme_file_info_escapes_the_filename', info, XSS)
  assert_present('theme_file_info_shows_the_escaped_name', info, '&lt;img')
end

io.write(('\n%d passed, %d failed\n'):format(pass_count, fail_count))

if fail_count > 0 then
  os.exit(1)
end
