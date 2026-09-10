--[[ The value and table helpers' contract.

  `empty()` is the one that matters. It is PHP semantics, it is reproduced from
  `seawolf.variable` exactly rather than improved, and the whole truth table is
  pinned here because two of its rows are load-bearing for authentication.
]]

local util = require 'includes.util'

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

io.write('test_util\n')

io.write '\n-- empty, the whole truth table --\n'

assert_eq('empty_nil', util.empty(nil), true)
assert_eq('empty_false', util.empty(false), true)
assert_eq('empty_empty_string', util.empty(''), true)
assert_eq('empty_empty_table', util.empty({}), true)
assert_eq('empty_true_is_false', util.empty(true), false)
assert_eq('empty_one', util.empty(1), false)
assert_eq('empty_space', util.empty(' '), false)
assert_eq('empty_text', util.empty('a'), false)
assert_eq('empty_array', util.empty({1}), false)

--[[ A table with only string keys is not empty. `next()` says so and `#` does
  not -- `get_user_roles()` returns exactly that shape, with `anonymous` and
  `authenticated` as string keys.
]]
assert_eq('empty_hash_only_table', util.empty({a = 1}), false)

--[[ The two rows that decide whether anonymous visitors are signed in.

  `is_logged_in()` is `not empty(session().user_id)` and anonymous is user id
  **0**. Drop `empty(0)` and every anonymous request reads as authenticated --
  silently, and in the permissive direction. `'0'` is the same hazard one step
  out, because a user id read back from a MySQL column can be a numeric string.
]]
assert_eq('empty_zero_is_true', util.empty(0), true)
assert_eq('empty_string_zero_is_true', util.empty('0'), true)
assert_eq('empty_float_zero_is_true', util.empty(0.0), true)

-- Always a boolean, never nil: call sites write `if empty(x) then`.
assert_eq('empty_returns_a_boolean', type(util.empty('a')), 'boolean')
assert_eq('empty_returns_a_boolean_for_nil', type(util.empty(nil)), 'boolean')

io.write '\n-- concat_deep --\n'

--[[ `pager_url()` appends `{'?page=', page}` as a table and relies on the
  descent to turn it back into `?page=2`. `table.concat` raises on it.
]]
assert_eq('concat_deep_flattens_nested_tables',
  util.concat_deep({'/tags', {'?page=', 2}, {'#', 'top'}}), '/tags?page=2#top')
assert_eq('concat_deep_takes_a_separator',
  util.concat_deep({'a', 'b'}, ','), 'a,b')
assert_eq('concat_deep_of_an_empty_table', util.concat_deep({}), '')
assert_eq('concat_deep_flattens_deeply',
  util.concat_deep({'a', {'b', {'c', {'d'}}}}), 'abcd')
assert_eq('concat_deep_coerces_numbers', util.concat_deep({1, 2}), '12')

io.write '\n-- rest --\n'

--[[ Named for what it does. Seawolf called this `table_shift`, which says it
  mutates, and it does not.
]]
do
  local source = {'route_page', 'a', 'b'}
  local tail = util.rest(source)

  assert_eq('rest_drops_the_first', table.concat(tail, ','), 'a,b')
  assert_eq('rest_does_not_mutate', #source, 3)
  assert_eq('rest_leaves_the_first_in_place', source[1], 'route_page')
end

--[[ Only the array part. `route.lua` hands over a route record carrying a
  `module` key and wants neither the callback name nor the module.
]]
do
  local record = {'route_page', module = 'entity'}
  local tail = util.rest(record)

  assert_eq('rest_of_a_single_element_is_empty', next(tail), nil)
  assert_eq('rest_drops_string_keys', tail.module, nil)
end

assert_eq('rest_of_an_empty_table', next(util.rest({})), nil)

io.write '\n-- dump --\n'

assert_eq('dump_a_number', util.dump(1), '1\n')
assert_eq('dump_a_string', util.dump('a'), '"a"\n')
assert_eq('dump_an_empty_table', util.dump({}), '{}\n')

--[[ A cycle has to terminate rather than recurse until the stack goes. Request
  state can reach itself.
]]
do
  local cyclic = {x = 1}
  cyclic.self = cyclic

  local rendered = util.dump(cyclic)

  assert_eq('dump_detects_a_cycle',
    rendered:find('self reference', 1, true) ~= nil, true)
  assert_eq('dump_still_renders_the_other_keys',
    rendered:find('x = 1', 1, true) ~= nil, true)
end

--[[ Seawolf's `print_r` declared its recursive helper without `local`, so it
  wrote the global `table_r` on every call -- a `_G` write guard warning per
  call under OpenResty, and worker state mutated from a debug helper.
]]
do
  local before = rawget(_G, 'table_r')

  util.dump({a = {b = 1}})

  assert_eq('dump_writes_no_globals', rawget(_G, 'table_r'), before)
end

io.write(('\n%d passed, %d failed\n'):format(pass_count, fail_count))

if fail_count > 0 then
  os.exit(1)
end
