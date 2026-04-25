-- Unit tests for shared settings loader and module override support.

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

local lfs = require 'lfs'

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

local function make_temp_dir()
  local path = os.tmpname()
  os.remove(path)
  assert(lfs.mkdir(path))
  return path
end

local function write_file(path, content)
  local fh = assert(io.open(path, 'w'))
  fh:write(content)
  fh:close()
end

local root = io.popen('pwd'):read('*l')
local real_path = package.path
local real_cwd = lfs.currentdir()

io.write '\n-- settings loader --\n'

do
  local tmp = make_temp_dir()
  local settings_dir = tmp .. '/settings'

  assert(lfs.mkdir(settings_dir))

  write_file(tmp .. '/settings.lua', [[
return function(settings)
  settings.modules.comment = true
  settings.modules.tag = false
end
]])

  write_file(tmp .. '/vault.lua', [[return {}]])

  package.path = table.concat({
    tmp .. '/?.lua',
    tmp .. '/?/init.lua',
    root .. '/?.lua',
    root .. '/?/init.lua',
    real_path,
  }, ';')

  lfs.chdir(tmp)
  package.loaded['settings'] = nil
  package.loaded['vault'] = nil
  package.loaded['settings.modules'] = nil
  package.loaded['includes.settings_loader'] = nil

  local loader = require 'includes.settings_loader'
  local settings = loader.build({include_module_overrides = false})

  assert_eq('base_comment_enabled', settings.modules.comment, true)
  assert_eq('base_tag_disabled', settings.modules.tag, false)

  write_file(settings_dir .. '/modules.lua', [[
return {
  comment = false,
  file = true,
}
]])

  package.loaded['settings'] = nil
  package.loaded['vault'] = nil
  package.loaded['settings.modules'] = nil
  settings = loader.build()

  assert_eq('override_comment_disabled', settings.modules.comment, false)
  assert_eq('override_file_enabled', settings.modules.file, true)
  assert_eq('override_preserves_base_tag', settings.modules.tag, false)

  write_file(settings_dir .. '/modules.lua', [[
return function(settings)
  settings.modules.comment = true
  settings.modules.file = false
  settings.modules.user = true
end
]])

  package.loaded['settings'] = nil
  package.loaded['vault'] = nil
  package.loaded['settings.modules'] = nil
  settings = loader.build()

  assert_eq('function_override_comment_enabled', settings.modules.comment, true)
  assert_eq('function_override_file_disabled', settings.modules.file, false)
  assert_eq('function_override_user_enabled', settings.modules.user, true)
end

lfs.chdir(real_cwd)
package.path = real_path

io.write(('\n%d passed, %d failed\n'):format(pass_count, fail_count))
if fail_count > 0 then
  os.exit(1)
end
