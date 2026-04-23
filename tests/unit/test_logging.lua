-- Unit tests for centralized structured logging helpers.

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

local function assert_truthy(label, got)
  if got then
    pass_count = pass_count + 1
    io.write(('  ok %s\n'):format(label))
  else
    fail_count = fail_count + 1
    io.write(('  FAIL %s: expected truthy, got %s\n'):format(label, tostring(got)))
  end
end

local real_stderr = io.stderr

local function load_logger()
  _G.settings = {logging = {level = 'debug'}}
  _G.ngx = nil
  dofile('includes/log.lua')
end

io.write '\n-- log formatting --\n'

load_logger()

do
  local line = log_format('warn', 'hello "world"', {
    b = 2,
    a = 'alpha beta',
    newline = 'one\ntwo',
  })

  assert_match('format_time', line, 'time="%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ"')
  assert_match('format_level_alias', line, 'level="warning"')
  assert_match('format_message_escaped', line, 'message="hello \\"world\\""')
  assert_match('format_context_number', line, 'b=2')
  assert_match('format_context_string', line, 'a="alpha beta"')
  assert_match('format_context_newline', line, 'newline="one\\ntwo"')
  assert_truthy('format_context_sorted', line:find('a="alpha beta"', 1, true) < line:find('b=2', 1, true))
end

io.write '\n-- log writer and levels --\n'

do
  local calls = {}

  settings.logging = {
    level = 'warning',
    writer = function(level, line, context)
      calls[#calls + 1] = {level = level, line = line, context = context}
    end,
  }

  assert_eq('debug_filtered', log_debug('hidden'), false)
  assert_eq('warn_logged', log_warn('visible', {event = 'unit_warning'}), true)
  assert_eq('writer_call_count', #calls, 1)
  assert_eq('writer_level', calls[1].level, 'warning')
  assert_match('writer_line_event', calls[1].line, 'event="unit_warning"')
  assert_eq('writer_context_preserved', calls[1].context.event, 'unit_warning')
end

io.write '\n-- disabled logging --\n'

do
  local calls = 0
  settings.logging = {
    enabled = false,
    writer = function()
      calls = calls + 1
    end,
  }

  assert_eq('disabled_returns_false', log_error('hidden'), false)
  assert_eq('disabled_skips_writer', calls, 0)
end

io.write '\n-- stderr fallback --\n'

do
  local captured = {}
  local mock_stderr = {
    write = function(_, text)
      captured[#captured + 1] = text
    end,
  }

  settings.logging = {level = 'error'}
  io.stderr = mock_stderr
  log_error('stderr path', {event = 'stderr_test'})
  io.stderr = real_stderr

  assert_eq('stderr_write_count', #captured, 1)
  assert_match('stderr_line', captured[1], 'event="stderr_test"')
end

io.write '\n-- OpenResty writer --\n'

do
  local ngx_calls = {}

  settings.logging = {level = 'info'}
  ngx = {
    INFO = 1,
    WARN = 2,
    ERR = 3,
    log = function(level, line)
      ngx_calls[#ngx_calls + 1] = {level = level, line = line}
    end,
  }

  log_warn('nginx path', {event = 'nginx_test'})
  ngx = nil

  assert_eq('nginx_log_count', #ngx_calls, 1)
  assert_eq('nginx_log_level', ngx_calls[1].level, 2)
  assert_match('nginx_log_line', ngx_calls[1].line, 'event="nginx_test"')
end

io.write(('\n%d passed, %d failed\n'):format(pass_count, fail_count))
if fail_count > 0 then
  os.exit(1)
end
