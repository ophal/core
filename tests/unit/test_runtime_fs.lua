-- Unit tests for runtime filesystem metadata caching on OpenResty paths.

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

local real_lfs = require 'lfs'
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

local function setup_env()
  local counts = {}


  _G.settings = {
    slash = '/',
    site = {name = 'My Site'},
    locale = {},
    language = 'en',
    language_dir = 'ltr',
    theme = {name = 'basic', js = {}, css = {}, head = {}},
    output_buffering = false,
    runtime_cache = {
      stat_ttl = 60,
    },
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
    version = nil,
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
  _G.echo = function() end
  _G.route_arg = function() return nil end
  _G.request_path = function() return '' end
  _G.format_date = function(value) return tostring(value or '') end
  _G.path_to_theme = function() return '/themes/basic' end
  _G.print_t = function() return '' end
  _G.print_f = function(format, ...)
    return string.format(format, ...)
  end
  _G.l = function(text)
    return text
  end
  _G.debug = {}
  _G.theme = {
    settings = {js = {}, css = {}, head = {}},
  }
  _G.lfs = {
    attributes = function(path, field)
      counts[path] = (counts[path] or 0) + 1
      return real_lfs.attributes(path, field)
    end,
    currentdir = function()
      return real_lfs.currentdir()
    end,
    dir = function(path)
      return real_lfs.dir(path)
    end,
  }

  package.loaded['includes.escape'] = nil
  package.loaded['includes.common'] = nil
  package.loaded['includes.theme'] = nil
  package.loaded['dkjson'] = nil

  dofile('includes/escape.lua')
  dofile('includes/common.lua')
  dofile('includes/theme.lua')

  return counts
end

io.write '\n-- format_size --\n'

--[[ It has never worked.

  `format_size()` calls `round()`, which was `seawolf.maths.round` -- and
  `seawolf.maths` requires an undeclared rock named `random` at its first line.
  `__build`'s `pcall` stores the resulting error *string* in the slot rather
  than leaving it nil, indexing a string is legal in Lua, so `round` resolved to
  nil with no complaint and every call raised "attempt to call a nil value".
  `theme.file_info` renders this, so a file's size has never displayed.

  These assertions are red on any tree where `round` is not a real function.
]]
do
  setup_env()

  assert_eq('format_size_zero', format_size(0), '0 B')
  assert_eq('format_size_bytes', format_size(512), '512 B')
  assert_eq('format_size_rounds_to_two_places', format_size(1536), '1.5 KB')
  assert_eq('format_size_megabytes', format_size(5242880), '5 MB')
  assert_eq('format_size_of_nil_is_zero', format_size(nil), '0 B')
end

io.write '\n-- asset stat cache --\n'

do
  local counts = setup_env()

  add_js 'libraries/jquery.min.js'
  get_js()
  assert_eq('asset_first_js_stat', counts['libraries/jquery.min.js'], 1)
  assert_eq('asset_first_ophal_js_stat', counts['libraries/ophal.js'], 1)

  get_js()
  assert_eq('asset_cached_js_stat', counts['libraries/jquery.min.js'], 1)
  assert_eq('asset_cached_ophal_js_stat', counts['libraries/ophal.js'], 1)

  get_css()
  assert_eq('asset_first_css_stat', counts['themes/basic/style.css'], 1)

  get_css()
  assert_eq('asset_cached_css_stat', counts['themes/basic/style.css'], 1)

  asset_cache_clear()
  get_css()
  assert_eq('asset_cache_clear_forces_stat', counts['themes/basic/style.css'], 2)
end

io.write '\n-- template stat cache --\n'

do
  local counts = setup_env()
  local footer_path = real_lfs.currentdir() .. '/themes/basic/footer.tpl.html'

  theme{'footer', _return = true}
  assert_eq('template_first_stat', counts[footer_path], 1)

  theme{'footer', _return = true}
  assert_eq('template_cached_stat', counts[footer_path], 1)

  template_cache_clear()
  theme{'footer', _return = true}
  assert_eq('template_cache_clear_forces_stat', counts[footer_path], 2)
end

io.write(('\n%d passed, %d failed\n'):format(pass_count, fail_count))
if fail_count > 0 then
  os.exit(1)
end
