-- Unit tests for pager page-number normalization.
--
-- `pager_current_page()` guards a cache key, not just a SQL offset: listing
-- pages interpolate its result into projection payload cache keys, so an
-- unclamped `?page=` value lets any visitor grow a worker's cache without
-- bound. These tests pin the clamping behavior that prevents that.

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

-- includes/pager.lua defines theme.pager at load time.
theme = theme or {}

require 'includes.pager'

io.write '\n-- pager current page --\n'

do
  assert_eq('page_in_range', pager_current_page('3', 5), 3)
  assert_eq('page_first', pager_current_page('1', 5), 1)
  assert_eq('page_last', pager_current_page('5', 5), 5)
  assert_eq('page_numeric_argument', pager_current_page(2, 5), 2)
end

do
  assert_eq('page_missing', pager_current_page(nil, 5), 1)
  assert_eq('page_empty_string', pager_current_page('', 5), 1)
  assert_eq('page_not_a_number', pager_current_page('abc', 5), 1)

  -- `?page=1&page=2` hands the module a table, not a string.
  assert_eq('page_table', pager_current_page({'1', '2'}, 5), 1)
end

do
  -- The unbounded-cache vector: every out-of-range value has to collapse onto
  -- an existing page rather than mint a distinct cache key.
  assert_eq('page_above_last', pager_current_page('9999', 5), 5)
  assert_eq('page_huge', pager_current_page('1e300', 5), 5)
  assert_eq('page_zero', pager_current_page('0', 5), 1)
  assert_eq('page_negative', pager_current_page('-7', 5), 1)

  -- Fractional pages would otherwise give an unbounded key space inside the
  -- valid range, so they truncate to a whole page.
  assert_eq('page_fractional', pager_current_page('2.7', 5), 2)
  assert_eq('page_fractional_near_one', pager_current_page('1.0000001', 5), 1)
  assert_eq('page_hex', pager_current_page('0x3', 5), 3)
end

do
  -- An empty listing reports zero pages; clamping still has to land on page 1.
  assert_eq('pages_zero', pager_current_page('4', 0), 1)
  assert_eq('pages_missing', pager_current_page('4', nil), 1)
  assert_eq('pages_negative', pager_current_page('4', -2), 1)

  -- ceil(count/ipp) is NaN when both are zero.
  assert_eq('pages_nan', pager_current_page('4', 0/0), 1)
  assert_eq('pages_fractional', pager_current_page('4', 3.5), 3)
end

io.write(('\n%d passed, %d failed\n'):format(pass_count, fail_count))
if fail_count > 0 then
  os.exit(1)
end
