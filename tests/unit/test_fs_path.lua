--[[ The path helpers' contract.

  `includes/fs/path.lua` replaced `seawolf.fs`'s path half. Every expectation
  here was measured from the vendored seawolf on 2026-09-10 before it was
  removed -- including `dirname('/index.lua')` being the empty string, which is
  not what POSIX `dirname` answers and is what three call sites are built on.
]]

local path = require 'includes.fs.path'

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

io.write('test_fs_path\n')

io.write '\n-- dirname --\n'

--[[ **Not POSIX.** `dirname('/index.lua')` is `/` to the shell and `''` here,
  because that is what seawolf answered and what the callers subtract.
  `server_normalize_path()` takes this length off a request path and
  `build_base()` trims it to decide whether Ophal sits in a subdirectory --
  answering `/` would take a character off every path on the site.
]]
assert_eq('dirname_of_a_root_file_is_empty', path.dirname('/index.lua'), '')
assert_eq('dirname_of_a_nested_file', path.dirname('/sub/index.lua'), '/sub')
assert_eq('dirname_of_a_deep_path', path.dirname('/a/b/c.lua'), '/a/b')
assert_eq('dirname_of_root_is_empty', path.dirname('/'), '')
assert_eq('dirname_of_nil_is_empty', path.dirname(nil), '')

-- Seawolf answered the whole string for a bare filename. Kept, because a call
-- site subtracting its length would shift if this became '' or '.'.
assert_eq('dirname_of_a_bare_filename', path.dirname('index.lua'), 'index.lua')

io.write '\n-- basename --\n'

assert_eq('basename_of_a_root_file', path.basename('/index.lua'), 'index.lua')
assert_eq('basename_of_a_nested_file', path.basename('/sub/index.lua'), 'index.lua')
assert_eq('basename_of_a_bare_filename', path.basename('index.lua'), 'index.lua')
assert_eq('basename_of_root_is_empty', path.basename('/'), '')
assert_eq('basename_of_nil_is_empty', path.basename(nil), '')

io.write '\n-- is_file and is_dir --\n'

assert_eq('is_file_on_a_file', path.is_file('includes/fs/path.lua'), true)
assert_eq('is_file_on_a_directory', path.is_file('includes'), false)
assert_eq('is_file_on_a_missing_path', path.is_file('no/such/file'), false)
assert_eq('is_dir_on_a_directory', path.is_dir('includes'), true)
assert_eq('is_dir_on_a_file', path.is_dir('includes/fs/path.lua'), false)
assert_eq('is_dir_on_a_missing_path', path.is_dir('no/such/dir'), false)

--[[ Both answer a boolean, never nil, and neither raises on a missing path.

  Seawolf's `is_file` tested the *error* `lfs.attributes` returns rather than
  the value -- `err == nil and file.mode == 'file'` -- so on any build where a
  miss answers nil with no message it indexed nil and raised. `is_dir` beside it
  already tested the value, so the two disagreed about how to ask the same
  question. Both test the value here.
]]
assert_eq('is_file_returns_a_boolean', type(path.is_file('no/such/file')), 'boolean')
assert_eq('is_dir_returns_a_boolean', type(path.is_dir('no/such/dir')), 'boolean')
assert_eq('is_file_of_nil_does_not_raise', path.is_file(nil), false)
assert_eq('is_dir_of_nil_does_not_raise', path.is_dir(nil), false)

io.write '\n-- temp_dir --\n'

do
  local value = path.temp_dir()

  assert_eq('temp_dir_is_a_string', type(value), 'string')
  assert_eq('temp_dir_is_not_empty', #value > 0, true)

  -- No trailing separator: all three call sites concatenate one themselves.
  assert_eq('temp_dir_has_no_trailing_separator',
    value:sub(-1) ~= '/', true)

  -- Memoized for the life of the worker, as seawolf's was.
  assert_eq('temp_dir_is_stable', path.temp_dir(), value)
end

io.write(('\n%d passed, %d failed\n'):format(pass_count, fail_count))

if fail_count > 0 then
  os.exit(1)
end
