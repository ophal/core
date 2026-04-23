-- Unit tests for the Ophal CLI dispatcher.

local cli = dofile('includes/cli.lua')

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

io.write '\n-- planned command stubs --\n'

do
  local code, stdout, stderr = run({'install'})

  assert_eq('install_stub_exit_code', code, 2)
  assert_eq('install_stub_stdout_empty', stdout, '')
  assert_match('install_stub_stderr', stderr, 'Command not implemented yet: install')
end

do
  local code, stdout, stderr = run({'migrate'})

  assert_eq('migrate_stub_exit_code', code, 2)
  assert_eq('migrate_stub_stdout_empty', stdout, '')
  assert_match('migrate_stub_stderr', stderr, 'Command not implemented yet: migrate')
end

do
  local code, stdout, stderr = run({'module', 'enable'})

  assert_eq('module_enable_missing_exit_code', code, 1)
  assert_eq('module_enable_missing_stdout_empty', stdout, '')
  assert_match('module_enable_missing_stderr', stderr, 'Usage: ophal module enable NAME')
end

do
  local code, stdout, stderr = run({'module', 'disable', 'comment'})

  assert_eq('module_disable_stub_exit_code', code, 2)
  assert_eq('module_disable_stub_stdout_empty', stdout, '')
  assert_match('module_disable_stub_stderr', stderr, 'Command not implemented yet: module disable comment')
end

io.write(('\n%d passed, %d failed\n'):format(pass_count, fail_count))
if fail_count > 0 then
  os.exit(1)
end
