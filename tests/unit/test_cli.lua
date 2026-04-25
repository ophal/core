-- Unit tests for the Ophal CLI dispatcher.

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

local cli = dofile('includes/cli.lua')
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

local function assert_eq_table(label, got, expected)
  local function render(tbl)
    local parts = {}
    for k, v in pairs(tbl or {}) do
      parts[#parts + 1] = ('%s=%s'):format(tostring(k), tostring(v))
    end
    table.sort(parts)
    return table.concat(parts, ',')
  end

  assert_eq(label, render(got), render(expected))
end

local function make_temp_dir()
  local path = os.tmpname()
  os.remove(path)
  assert(lfs.mkdir(path))
  return path
end

local function run(args, options)
  local stdout, stderr = {}, {}

  options = options or {}
  options.stdout = function(text)
    stdout[#stdout + 1] = text
  end
  options.stderr = function(text)
    stderr[#stderr + 1] = text
  end

  return cli.run(args, options), table.concat(stdout), table.concat(stderr)
end

io.write '\n-- help and unknown commands --\n'

do
  local code, stdout, stderr = run({})

  assert_eq('help_exit_code', code, 0)
  assert_match('help_usage', stdout, 'Usage: ophal COMMAND')
  assert_eq('help_stderr_empty', stderr, '')
end

do
  local code, stdout, stderr = run({'unknown'})

  assert_eq('unknown_exit_code', code, 1)
  assert_eq('unknown_stdout_empty', stdout, '')
  assert_match('unknown_stderr', stderr, 'Unknown command: unknown')
end

io.write '\n-- cache clear --\n'

do
  local called = false
  local code, stdout, stderr = run({'cache', 'clear'}, {
    cache_clear_all = function()
      called = true
    end,
  })

  assert_eq('cache_clear_exit_code', code, 0)
  assert_eq('cache_clear_called', called, true)
  assert_eq('cache_clear_stdout', stdout, 'Caches cleared.\n')
  assert_eq('cache_clear_stderr_empty', stderr, '')
end

do
  local code, stdout, stderr = run({'cache', 'clear'}, {
    cache_clear_all = function()
      error('boom')
    end,
  })

  assert_eq('cache_clear_failure_code', code, 1)
  assert_eq('cache_clear_failure_stdout_empty', stdout, '')
  assert_match('cache_clear_failure_stderr', stderr, 'cache clear failed:')
  assert_match('cache_clear_failure_message', stderr, 'boom')
end

do
  local code, stdout, stderr = run({'cache'})

  assert_eq('cache_usage_exit_code', code, 1)
  assert_eq('cache_usage_stdout_empty', stdout, '')
  assert_match('cache_usage_stderr', stderr, 'Usage: ophal cache clear')
end

io.write '\n-- legacy sha256 command --\n'

do
  local code, stdout, stderr = run({'sha256', 'secret'})

  assert_eq('sha256_exit_code', code, 0)
  assert_eq('sha256_digest', stdout, '2bb80d537b1da3e38bd30361aa855686bde0eacd7162fef6a25fe97bf527a25b\n')
  assert_eq('sha256_stderr_empty', stderr, '')
end

do
  local code, stdout, stderr = run({'sha256'})

  assert_eq('sha256_usage_exit_code', code, 1)
  assert_eq('sha256_usage_stdout_empty', stdout, '')
  assert_match('sha256_usage_stderr', stderr, 'Usage: ophal sha256 PASSWORD')
end

io.write '\n-- install and migrate commands --\n'

do
  local code, stdout, stderr = run({'install', 'check'}, {
    install_check = function()
      return {
        ok = false,
        dependencies = {
          {name = 'LuaSocket', machine_name = 'socket.url', found = true},
          {name = 'luuid', machine_name = 'uuid', found = false},
        },
        settings_exists = false,
        vault_exists = false,
      }
    end,
  })

  assert_eq('install_check_exit_code', code, 1)
  assert_match('install_check_found_stdout', stdout, 'FOUND   LuaSocket %(socket%.url%)')
  assert_match('install_check_missing_stdout', stdout, 'MISSING luuid %(uuid%)')
  assert_match('install_check_summary_stdout', stdout, 'Dependency summary: 1 found, 1 missing')
  assert_match('install_check_settings_stdout', stdout, 'settings%.lua: absent')
  assert_match('install_check_files_stdout', stdout, 'files directory: not checked')
  assert_eq('install_check_stderr_empty', stderr, '')
end

do
  local code, stdout, stderr = run({'install', 'init', '/tmp/site', '--site-name', 'CLI Site', '--module', 'comment'}, {
    install_init = function()
      return {
        settings_path = '/tmp/site/settings.lua',
        vault_path = '/tmp/site/vault.lua',
        files_dir = '/tmp/site/files',
        htaccess_path = '/tmp/site/files/.htaccess',
      }
    end,
  })

  assert_eq('install_init_exit_code', code, 0)
  assert_match('install_init_settings_stdout', stdout, '/tmp/site/settings%.lua')
  assert_match('install_init_vault_stdout', stdout, '/tmp/site/vault%.lua')
  assert_match('install_init_files_stdout', stdout, '/tmp/site/files')
  assert_match('install_init_htaccess_stdout', stdout, '/tmp/site/files/%.htaccess')
  assert_eq('install_init_stderr_empty', stderr, '')
end

do
  local code, stdout, stderr = run({'install', 'init', '--site-name'}, {})

  assert_eq('install_usage_exit_code', code, 1)
  assert_eq('install_usage_stdout_empty', stdout, '')
  assert_match('install_usage_stderr', stderr, 'missing value for %-%-site%-name')
end

do
  local code, stdout, stderr = run({'install', 'init'}, {
    install_init = function()
      return nil, 'settings file already exists: ./settings.lua'
    end,
  })

  assert_eq('install_init_failure_exit_code', code, 1)
  assert_eq('install_init_failure_stdout_empty', stdout, '')
  assert_match('install_init_failure_stderr', stderr, 'install init failed: settings file already exists')
end

do
  local code, stdout, stderr = run({'migrate', 'status'}, {
    migrate_status = function()
      return {
        applied_count = 1,
        pending_count = 2,
        pending = {
          {id = 'core:001_core'},
          {id = 'comment:001_comment'},
        },
      }
    end,
  })

  assert_eq('migrate_status_exit_code', code, 0)
  assert_match('migrate_status_stdout', stdout, 'Migration status: 1 applied, 2 pending')
  assert_match('migrate_status_pending_core', stdout, 'core:001_core')
  assert_match('migrate_status_pending_comment', stdout, 'comment:001_comment')
  assert_eq('migrate_status_stderr_empty', stderr, '')
end

do
  local code, stdout, stderr = run({'migrate'}, {
    migrate_apply = function()
      return {
        applied_count = 2,
        applied = {
          {id = 'core:001_core'},
          {id = 'comment:001_comment'},
        },
      }
    end,
  })

  assert_eq('migrate_apply_exit_code', code, 0)
  assert_match('migrate_apply_stdout', stdout, 'Applied 2 migration%(s%).')
  assert_match('migrate_apply_core', stdout, 'core:001_core')
  assert_match('migrate_apply_comment', stdout, 'comment:001_comment')
  assert_eq('migrate_apply_stderr_empty', stderr, '')
end

do
  local code, stdout, stderr = run({'migrate', 'apply'}, {
    migrate_apply = function()
      return {
        applied_count = 0,
        applied = {},
      }
    end,
  })

  assert_eq('migrate_apply_none_exit_code', code, 0)
  assert_eq('migrate_apply_none_stdout', stdout, 'No pending migrations.\n')
  assert_eq('migrate_apply_none_stderr_empty', stderr, '')
end

do
  local code, stdout, stderr = run({'migrate', 'bogus'})

  assert_eq('migrate_usage_exit_code', code, 1)
  assert_eq('migrate_usage_stdout_empty', stdout, '')
  assert_match('migrate_usage_stderr', stderr, 'Usage: ophal migrate %[status|apply%]')
end

do
  local code, stdout, stderr = run({'migrate'}, {
    migrate_apply = function()
      return nil, 'db down'
    end,
  })

  assert_eq('migrate_failure_exit_code', code, 1)
  assert_eq('migrate_failure_stdout_empty', stdout, '')
  assert_match('migrate_failure_stderr', stderr, 'migrate apply failed: db down')
end

io.write '\n-- module enable/disable --\n'

do
  local code, stdout, stderr = run({'module', 'enable'})

  assert_eq('module_enable_missing_exit_code', code, 1)
  assert_eq('module_enable_missing_stdout_empty', stdout, '')
  assert_match('module_enable_missing_stderr', stderr, 'Usage: ophal module enable NAME')
end

do
  local stored_overrides = {}
  local writes = {}
  local options = {
    load_settings = function()
      return {modules = {comment = true}}
    end,
    read_module_overrides = function()
      return {
        comment = stored_overrides.comment,
      }
    end,
    write_module_overrides = function(path, overrides)
      writes[#writes + 1] = {path = path, overrides = overrides}
      stored_overrides = overrides
    end,
    module_exists = function(name)
      return name == 'comment'
    end,
  }

  local code, stdout, stderr = run({'module', 'disable', 'comment'}, options)

  assert_eq('module_disable_exit_code', code, 0)
  assert_match('module_disable_stdout', stdout, "Module 'comment' disabled via settings/modules.lua")
  assert_eq('module_disable_stderr_empty', stderr, '')
  assert_eq('module_disable_write_count', #writes, 1)
  assert_eq_table('module_disable_override_false', writes[1].overrides, {comment = false})

  code, stdout, stderr = run({'module', 'disable', 'comment'}, options)
  assert_eq('module_disable_already_exit_code', code, 0)
  assert_match('module_disable_already_stdout', stdout, "Module 'comment' already disabled")
  assert_eq('module_disable_already_write_count', #writes, 1)

  code, stdout, stderr = run({'module', 'enable', 'comment'}, options)
  assert_eq('module_enable_restores_exit_code', code, 0)
  assert_match('module_enable_restores_stdout', stdout, "Module 'comment' enabled via settings/modules.lua")
  assert_eq('module_enable_restores_write_count', #writes, 2)
  assert_eq_table('module_enable_restores_override_removed', writes[2].overrides, {})
end

do
  local stored_overrides = {}
  local writes = {}
  local options = {
    load_settings = function()
      return {modules = {}}
    end,
    read_module_overrides = function()
      return stored_overrides
    end,
    write_module_overrides = function(path, overrides)
      writes[#writes + 1] = {path = path, overrides = overrides}
      stored_overrides = overrides
    end,
    module_exists = function(name)
      return name == 'comment'
    end,
  }

  local code, stdout = run({'module', 'enable', 'comment'}, options)
  assert_eq('module_enable_new_exit_code', code, 0)
  assert_match('module_enable_new_stdout', stdout, "Module 'comment' enabled via settings/modules.lua")
  assert_eq_table('module_enable_new_override_true', writes[1].overrides, {comment = true})

  code, stdout = run({'module', 'disable', 'comment'}, options)
  assert_eq('module_disable_removes_override_exit_code', code, 0)
  assert_match('module_disable_removes_override_stdout', stdout, "Module 'comment' disabled via settings/modules.lua")
  assert_eq_table('module_disable_removes_override', writes[2].overrides, {})
end

do
  local code, stdout, stderr = run({'module', 'disable', 'system'}, {
    load_settings = function() return {modules = {system = true}} end,
    read_module_overrides = function() return {} end,
    module_exists = function() return true end,
  })

  assert_eq('module_disable_system_exit_code', code, 1)
  assert_eq('module_disable_system_stdout_empty', stdout, '')
  assert_match('module_disable_system_stderr', stderr, 'system module cannot be disabled')
end

do
  local code, stdout, stderr = run({'module', 'enable', 'missing'}, {
    load_settings = function() return {modules = {}} end,
    read_module_overrides = function() return {} end,
    module_exists = function() return false end,
  })

  assert_eq('module_unknown_exit_code', code, 1)
  assert_eq('module_unknown_stdout_empty', stdout, '')
  assert_match('module_unknown_stderr', stderr, 'unknown module: missing')
end

do
  local tmp = make_temp_dir()
  local original_cwd = lfs.currentdir()
  local modules_path = tmp .. '/settings/modules.lua'
  local code, stdout, stderr
  local fh, content

  lfs.chdir('/sandbox')
  code, stdout, stderr = run({'module', 'disable', 'comment'}, {
    modules_file = modules_path,
    load_settings = function()
      return {modules = {comment = true}}
    end,
    module_exists = function(name)
      return name == 'comment'
    end,
  })
  lfs.chdir(original_cwd)

  assert_eq('module_disable_real_file_exit_code', code, 0)
  assert_match('module_disable_real_file_stdout', stdout, "Module 'comment' disabled via " .. modules_path:gsub('%%', '%%%%'))
  assert_eq('module_disable_real_file_stderr_empty', stderr, '')
  assert_eq('module_disable_real_file_exists', lfs.attributes(tmp .. '/settings', 'mode'), 'directory')

  fh = assert(io.open(modules_path, 'r'))
  content = fh:read('*a')
  fh:close()
  assert_match('module_disable_real_file_content', content, '%["comment"%] = false')
end

io.write(('\n%d passed, %d failed\n'):format(pass_count, fail_count))
if fail_count > 0 then
  os.exit(1)
end
