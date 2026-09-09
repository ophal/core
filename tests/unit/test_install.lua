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

local function find_dependency(result, machine_name)
  for _, dependency in ipairs(result.dependencies or {}) do
    if dependency.machine_name == machine_name then
      return dependency
    end
  end

  return nil
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

do
  local default_vault = install.render_vault({
    site_hash = 'hash-234',
  })
  local sqlite_vault = install.render_vault({
    site_hash = 'hash-345',
    db_driver = 'SQLite3',
  })

  assert_match('render_vault_default_postgres_driver', default_vault, 'driver = "PostgreSQL"')
  assert_match('render_vault_default_postgres_database', default_vault, 'database = "ophal"')
  assert_match('render_vault_sqlite_driver', sqlite_vault, 'driver = "SQLite3"')
  assert_match('render_vault_sqlite_database', sqlite_vault, 'database = "ophal%.sqlite3"')
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
  assert_match('init_vault_default_driver', vault_content, 'driver = "PostgreSQL"')
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
  local missing
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
  missing = find_dependency(result, 'uuid')
  assert_eq('check_missing_dependency_found', missing ~= nil, true)
  assert_match('check_missing_dependency', missing and missing.machine_name or '', 'uuid')
  assert_eq('check_missing_found_false', missing and missing.found, false)
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
  assert_eq('check_driver_postgres', result.database_driver, 'PostgreSQL')
  assert_eq('check_runtime_warning_absent', result.runtime_warning, nil)
  assert_eq('check_files_writable', result.files_writable, true)
  assert_match('check_files_dir', result.files_dir, 'sitefiles$')
end

do
  local tmp = make_temp_dir()
  assert(install.init({
    output_dir = tmp,
    site_hash = 'shared-hash-6',
    db_driver = 'SQLite3',
  }))

  local result = install.check({
    output_dir = tmp,
    require_module = function()
      return {}
    end,
    lfs = lfs,
  })

  assert_eq('check_sqlite_driver', result.database_driver, 'SQLite3')
  assert_match('check_sqlite_warning', result.runtime_warning or '', 'PostgreSQL is the required production backend')
end

io.write '\n-- database drivers --\n'

--[[ The installer used to answer PostgreSQL for every name it did not know.

  So `--db-driver mysql` wrote a PostgreSQL vault and `install check` reported a
  MySQL site as PostgreSQL, silently, for the whole stage in which MySQL became
  a supported backend. The names come from `includes/database/config.lua` now,
  which is the same list the connection layer refuses an unknown driver against.
]]
do
  local mysql_vault = install.render_vault({
    site_hash = 'hash-456',
    db_driver = 'mysql',
  })
  local unknown_vault, unknown_err = install.render_vault({
    site_hash = 'hash-567',
    db_driver = 'nonsense',
  })
  local retired_vault, retired_err = install.render_vault({
    site_hash = 'hash-678',
    db_driver = 'luadbi-postgresql',
  })

  assert_match('render_vault_mysql_driver', mysql_vault, 'driver = "MySQL"')
  assert_match('render_vault_mysql_port', mysql_vault, 'port = "3306"')
  -- The credential block used to be written for the literal name PostgreSQL,
  -- so a MySQL vault would have carried a database and no way to reach it.
  assert_match('render_vault_mysql_credentials', mysql_vault, 'username = "ophal"')
  assert_eq('render_vault_unknown_driver_refused', unknown_vault, nil)
  assert_match('render_vault_unknown_driver_lists_known', unknown_err or '',
    'known: MySQL, PostgreSQL, SQLite3')
  assert_eq('render_vault_retired_driver_refused', retired_vault, nil)
  assert_match('render_vault_retired_driver_names_replacement', retired_err or '',
    'postgresql')
end

do
  local tmp = make_temp_dir()
  local result, err = install.init({
    output_dir = tmp,
    site_hash = 'shared-hash-7',
    db_driver = 'nonsense',
  })

  assert_eq('init_unknown_driver_refused', result, nil)
  assert_match('init_unknown_driver_message', err or '', 'unknown database driver')
  assert_eq('init_unknown_driver_wrote_nothing',
    lfs.attributes(tmp .. '/settings.lua', 'mode'), nil)
end

do
  local tmp = make_temp_dir()
  assert(install.init({
    output_dir = tmp,
    site_hash = 'shared-hash-8',
    db_driver = 'mysql',
  }))

  local result = install.check({
    output_dir = tmp,
    require_module = function()
      return {}
    end,
    lfs = lfs,
  })

  assert_eq('check_mysql_driver', result.database_driver, 'MySQL')
  assert_eq('check_mysql_ok', result.ok, true)
  -- The operational difference stage 8.7 landed: no blocking mode, so the
  -- command line runs under resty.
  assert_match('check_mysql_warning', result.runtime_warning or '', 'under resty')
end

--[[ A vault naming a driver no binding answers to.

  `install.init()` refuses to write one, so this is hand-written -- which is
  also how it happens in life: a settings file carried across an upgrade.
  Reported here rather than left to raise from the site's first query, which is
  what `install check` is for.
]]
do
  local tmp = make_temp_dir()
  local vault_path = tmp .. '/vault.lua'
  local handle, contents

  assert(install.init({
    output_dir = tmp,
    site_hash = 'shared-hash-9',
    db_driver = 'SQLite3',
  }))

  contents = read_file(vault_path):gsub('driver = "SQLite3"', 'driver = "luadbi-sqlite3"')
  handle = assert(io.open(vault_path, 'w'))
  handle:write(contents)
  handle:close()

  local result = install.check({
    output_dir = tmp,
    require_module = function()
      return {}
    end,
    lfs = lfs,
  })

  assert_eq('check_unknown_driver_not_ok', result.ok, false)
  assert_eq('check_unknown_driver_unnamed', result.database_driver, nil)
  assert_match('check_unknown_driver_names_replacement',
    result.database_error or '', 'sqlite3')
end

io.write(('\n%d passed, %d failed\n'):format(pass_count, fail_count))
if fail_count > 0 then
  os.exit(1)
end
