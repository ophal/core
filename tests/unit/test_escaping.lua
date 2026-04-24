-- Unit tests for context-specific escaping helpers and framework boundaries.

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

local function assert_contains(label, got, needle)
  if tostring(got):find(needle, 1, true) then
    pass_count = pass_count + 1
    io.write(('  ok %s\n'):format(label))
  else
    fail_count = fail_count + 1
    io.write(('  FAIL %s: %q did not contain %q\n'):format(
      label, tostring(got), needle))
  end
end

local function assert_not_match(label, got, pattern)
  if not tostring(got):match(pattern) then
    pass_count = pass_count + 1
    io.write(('  ok %s\n'):format(label))
  else
    fail_count = fail_count + 1
    io.write(('  FAIL %s: %q unexpectedly matched %q\n'):format(
      label, tostring(got), pattern))
  end
end

local function setup_env()
  local seawolf = require 'seawolf'

  seawolf.__build('maths', 'text', 'fs', 'variable', 'contrib')

  _G.settings = {
    slash = '/',
    site = {name = 'My <Site>'},
    locale = {},
    theme = {name = 'basic', js = {}, css = {}, head = {}},
    output_buffering = false,
  }
  _G.base = {
    route = '/',
    system_root = 'http://example.com',
  }
  _G.ophal = {
    title = nil,
    header_title = nil,
    blocks = {},
    regions = {},
    modules = {},
  }
  _G.theme = {
    settings = {js = {}, css = {}, head = {}},
  }
  _G.mobile = {
    detect = {
      isMobile = function() return false end,
    },
  }
  _G._SERVER = function()
    return nil
  end
  _G.header = function() end
  _G.module_invoke_all = function() end
  _G.csrf_token = function() return 'csrf-token-1' end
  _G.session_write_close = function() end
  _G.server_exit = function() end
  _G.print = function() end
  _G.lfs = require 'lfs'
  _G.seawolf = seawolf

  package.loaded['includes.escape'] = nil
  package.loaded['includes.common'] = nil
  package.loaded['includes.theme'] = nil

  dofile('includes/escape.lua')
  dofile('includes/common.lua')
  dofile('includes/theme.lua')
  dofile('includes/form.lua')
end

io.write '\n-- helper escaping --\n'

setup_env()

assert_eq('html_escape_basic', html_escape([[<a&b>]]), '&lt;a&amp;b&gt;')
assert_eq('html_attr_escape_quotes', html_attr_escape('"' .. "'" .. "\n"), '&quot;&#39;&#10;')
assert_eq('url_rejects_javascript', html_sanitize_url('javascript:alert(1)'), '#')
assert_eq('url_allows_relative', html_sanitize_url('/content/1?q=1'), '/content/1?q=1')
assert_eq('js_escapes_script_end', js_escape_json([[</script>]]), [[<\/script>]])

io.write '\n-- page titles --\n'

page_set_title('Hello <world>')
assert_eq('page_title_escaped', ophal.title, 'Hello &lt;world&gt;')
assert_eq('page_header_escaped', ophal.header_title, 'Hello &lt;world&gt; | My &lt;Site&gt;')

page_set_title('Linked title', html_safe('<a href="/x">X</a>'))
assert_eq('page_title_safe_html', ophal.title, '<a href="/x">X</a>')
assert_eq('page_header_safe_header_text', ophal.header_title, 'Linked title | My &lt;Site&gt;')

io.write '\n-- attribute and link rendering --\n'

do
  local attrs = render_attributes({
    title = [["bad" & <ok>]],
    onclick = 'alert(1)',
    checked = true,
    disabled = false,
    ['data-id'] = '1&2',
  })

  assert_match('attr_title_escaped', attrs, 'title="&quot;bad&quot; &amp; &lt;ok&gt;"')
  assert_match('attr_data_escaped', attrs, 'data%-id="1&amp;2"')
  assert_match('attr_true_as_name', attrs, 'checked="checked"')
  assert_not_match('attr_skips_false', attrs, 'disabled=')
  assert_not_match('attr_skips_event_handlers', attrs, 'onclick=')
end

do
  local anchor = theme{'a',
    route = 'javascript:alert(1)',
    text = '<strong>x</strong>',
  }

  assert_match('anchor_sanitized_href', anchor, 'href="#"')
  assert_match('anchor_escaped_text', anchor, '&lt;strong&gt;x&lt;/strong&gt;')
end

do
  local anchor = theme{'a',
    route = '/safe',
    text = html_safe('<strong>x</strong>'),
  }

  assert_match('anchor_safe_text', anchor, '<strong>x</strong>')
end

io.write '\n-- form controls --\n'

do
  local textfield = theme{'textfield',
    attributes = {id = 'name'},
    value = [["x"<tag>]],
  }
  assert_match('textfield_value_escaped', textfield, 'value="&quot;x&quot;&lt;tag&gt;"')

  local textarea = theme{'textarea',
    attributes = {id = 'body'},
    value = '<body>',
    description = [["quote"]],
  }
  assert_match('textarea_value_escaped', textarea, '&lt;body&gt;')
  assert_match('textarea_description_escaped', textarea, '"quote"')

  local option = theme{'select_option', key = [["1"]], value = '<One>', selected = true}
  assert_match('select_option_key_escaped', option, 'value="&quot;1&quot;"')
  assert_match('select_option_value_escaped', option, '&lt;One&gt;')
end

io.write '\n-- javascript settings --\n'

do
  add_js {type = 'settings', namespace = [[bad"</script>]], {danger = [[</script><script>alert(1)</script>]]}}
  add_js {'javascript:alert(1)', type = 'external'}
  local js = get_js().header or ''

  assert_not_match('js_no_script_breakout', js, '</script><script>')
  assert_match('js_contains_escaped_script_end', js, '<\\/script>')
  assert_not_match('js_namespace_raw', js, 'bad"</script>')
  assert_contains('js_namespace_quote_escaped', js, [[bad\"]])
  assert_contains('js_namespace_script_end_escaped', js, [[bad\"<\/script>]])
  assert_match('js_external_url_sanitized', js, 'src="#"')
end

io.write(('\n%d passed, %d failed\n'):format(pass_count, fail_count))
if fail_count > 0 then
  os.exit(1)
end
