-- Unit tests for install helpers and CLI-facing installer scaffolding.

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

local install = dofile('includes/install.lua')
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

local function make_temp_dir()
  local path = os.tmpname()
  os.remove(path)
  assert(lfs.mkdir(path))
  return path
end

local function read_file(path)
  local fh = assert(io.open(path, 'r'))
  local content = fh:read('*a')
  fh:close()
  return content
end

io.write '\n-- render helpers --\n'

do
  local settings = install.render_settings({
    site_name = 'My Site',
    files_path = 'uploads',
    site_hash = 'hash-123',
    modules_enabled = {'comment'},
  })
  local vault = install.render_vault({
    site_hash = 'hash-123',
    db_driver = 'PostgreSQL',
    db_database = 'ophal_prod',
    db_username = 'user1',
    db_password = 'secret1',
    db_host = 'db.local',
    db_port = '5444',
  })

  assert_match('render_settings_site_name', settings, "name = \"My Site\"")
  assert_match('render_settings_files_path', settings, "files_path = \"uploads\"")
  assert_match('render_settings_comment_module', settings, '%["comment"%] = true')
  assert_match('render_vault_hash', vault, 'hash%-123')
  assert_match('render_vault_postgres_driver', vault, 'driver = "PostgreSQL"')
  assert_match('render_vault_postgres_host', vault, 'host = "db%.local"')
end

io.write '\n-- init --\n'

do
  local tmp = make_temp_dir()
  local result = assert(install.init({
    output_dir = tmp,
    site_name = 'CLI Site',
    site_hash = 'shared-hash-1',
    files_path = 'files',
    modules_enabled = {'comment'},
  }))
  local settings_content = read_file(result.settings_path)
  local vault_content = read_file(result.vault_path)
  local htaccess_content = read_file(result.htaccess_path)

  assert_eq('init_settings_exists', lfs.attributes(result.settings_path, 'mode'), 'file')
  assert_eq('init_vault_exists', lfs.attributes(result.vault_path, 'mode'), 'file')
  assert_eq('init_files_dir_exists', lfs.attributes(result.files_dir, 'mode'), 'directory')
  assert_match('init_settings_comment_module', settings_content, '%["comment"%] = true')
  assert_match('init_settings_hash_indirect', settings_content, 'hash = vault%.site%.hash')
  assert_match('init_vault_shared_hash', vault_content, 'shared%-hash%-1')
  assert_match('init_htaccess_content', htaccess_content, 'SetHandler Ophal_Security_Do_Not_Remove')
end

do
  local tmp = make_temp_dir()
  local first = assert(install.init({
    output_dir = tmp,
    site_hash = 'shared-hash-2',
  }))
  local result, err = install.init({
    output_dir = tmp,
    site_hash = 'shared-hash-3',
  })

  assert_eq('init_existing_result_nil', result, nil)
  assert_match('init_existing_error', err, 'settings file already exists')

  result, err = install.init({
    output_dir = tmp,
    site_hash = 'shared-hash-4',
    force = true,
  })

  assert_eq('init_force_path_same', result.settings_path, first.settings_path)
  assert_match('init_force_new_hash', read_file(result.vault_path), 'shared%-hash%-4')
end

io.write '\n-- check --\n'

do
  local tmp = make_temp_dir()
  local result = install.check({
    output_dir = tmp,
    require_module = function(name)
      if name == 'uuid' then
        error("module 'uuid' not found")
      end
      return {}
    end,
  })

  assert_eq('check_missing_ok', result.ok, false)
  assert_eq('check_settings_absent', result.settings_exists, false)
  assert_eq('check_vault_absent', result.vault_exists, false)
  assert_match('check_missing_dependency', result.dependencies[3].machine_name, 'uuid')
  assert_eq('check_missing_found_false', result.dependencies[3].found, false)
end

do
  local tmp = make_temp_dir()
  assert(install.init({
    output_dir = tmp,
    site_hash = 'shared-hash-5',
    files_path = 'sitefiles',
  }))

  local result = install.check({
    output_dir = tmp,
    require_module = function()
      return {}
    end,
    lfs = lfs,
  })

  assert_eq('check_installed_ok', result.ok, true)
  assert_eq('check_settings_present', result.settings_exists, true)
  assert_eq('check_vault_present', result.vault_exists, true)
  assert_eq('check_files_writable', result.files_writable, true)
  assert_match('check_files_dir', result.files_dir, 'sitefiles$')
end

io.write(('\n%d passed, %d failed\n'):format(pass_count, fail_count))
if fail_count > 0 then
  os.exit(1)
end
