--[[ The text helpers' contract.

  `includes/text.lua` replaced `seawolf.text`, and most of what matters here is
  that it did **not** change: the request path splits query strings, cookie
  headers and route paths with these, so a difference in how an empty field or a
  trailing delimiter is treated changes what URL resolves to what page.

  Every expectation below was measured from the vendored seawolf on 2026-09-10,
  before it was removed, rather than reasoned about -- except the four marked as
  deliberate divergences, which are the cases where seawolf's behaviour was a
  defect.
]]

local text = require 'includes.text'

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

local function assert_list(label, got, expected)
  local same = #got == #expected

  if same then
    for i = 1, #expected do
      if got[i] ~= expected[i] then
        same = false
        break
      end
    end
  end

  if same then
    pass_count = pass_count + 1
    io.write(('  ok %s\n'):format(label))
  else
    fail_count = fail_count + 1
    io.write(('  FAIL %s: expected [%s], got [%s]\n'):format(
      label, table.concat(expected, ','), table.concat(got, ',')))
  end
end

io.write('test_text\n')

io.write '\n-- split keeps empty fields, which is the whole contract --\n'

--[[ `route_arg()` splits the request path with this, so an empty field is a
  route argument. A `gmatch('[^/]+')` drops every one of these and would change
  what `content/view/` resolves to without changing any test that only looks at
  well-formed paths.
]]
assert_list('split_three_fields', text.split('/', 'a/b/c'), {'a', 'b', 'c'})
assert_list('split_keeps_a_trailing_empty_field',
  text.split('/', 'a/b/'), {'a', 'b', ''})
assert_list('split_keeps_a_leading_empty_field',
  text.split('/', '/a'), {'', 'a'})
assert_list('split_of_the_empty_string_is_one_empty_field',
  text.split('/', ''), {''})
assert_list('split_without_a_delimiter_is_one_field',
  text.split('/', 'a'), {'a'})
assert_list('split_keeps_a_doubled_delimiter',
  text.split('&', 'a=1&&b=2'), {'a=1', '', 'b=2'})
assert_list('split_keeps_an_interior_empty_field',
  text.split('/', 'a//b'), {'a', '', 'b'})
assert_list('split_of_nil_is_one_empty_field', text.split('/', nil), {''})

--[[ Seawolf ran the delimiter through `lpeg.P`, which made it literal. Here it
  goes into a character class, so it is escaped -- otherwise a delimiter that is
  a pattern metacharacter would split on something else entirely.
]]
assert_list('split_on_a_pattern_metacharacter',
  text.split('.', 'a.b.c'), {'a', 'b', 'c'})
assert_list('split_on_a_percent', text.split('%', 'a%b'), {'a', 'b'})

io.write '\n-- trim --\n'

assert_eq('trim_both_ends', text.trim('  x  '), 'x')
assert_eq('trim_of_the_empty_string', text.trim(''), '')
assert_eq('trim_of_nil_is_the_empty_string', text.trim(nil), '')
assert_eq('trim_keeps_interior_whitespace', text.trim('a  b'), 'a  b')
assert_eq('trim_all_whitespace_is_empty', text.trim('   '), '')
assert_eq('trim_tab_and_newline', text.trim('\ta\n'), 'a')

--[[ A charlist is a set of characters, so every one of them is stripped from
  either end in any order -- not a sequence to match.
]]
assert_eq('trim_takes_a_character_set', text.trim('/a/b/', '/'), 'a/b')
assert_eq('trim_leaves_what_is_not_in_the_set', text.trim('x', '/'), 'x')
assert_eq('trim_strips_several_characters_of_the_set',
  text.trim('/,\\a/', '\\,/'), 'a')

--[[ Deliberate divergence 1. Seawolf's default set was `' \t\n\r\0\v'`: it
  counted NUL as whitespace and missed a form feed. A NUL is not whitespace, and
  trimming one silently turns a value a later check would reject into one it
  accepts -- `safe_path_segment()` rejects NUL on purpose.
]]
assert_eq('trim_does_not_strip_a_nul', text.trim('\0a\0'), '\0a\0')
assert_eq('trim_strips_a_form_feed', text.trim('\fa\f'), 'a')

io.write '\n-- ltrim and rtrim --\n'

assert_eq('ltrim_strips_the_front', text.ltrim('///a', '/'), 'a')
assert_eq('ltrim_leaves_the_back', text.ltrim('/a/', '/'), 'a/')
assert_eq('rtrim_strips_the_back', text.rtrim('a///', '/'), 'a')
assert_eq('rtrim_leaves_the_front', text.rtrim('/a/', '/'), '/a')

--[[ Deliberate divergence 2. Seawolf's `ltrim` was `return str:gsub(...)`,
  which leaks `gsub`'s count as a second return value -- so `ltrim(x, '/')` in
  an argument list silently became two arguments. Its one call site concatenated
  the result, which hid it.
]]
assert_eq('ltrim_returns_one_value', select('#', text.ltrim('///a', '/')), 1)

--[[ Deliberate divergence 3, and the one with a real call site behind it.
  Seawolf's `rtrim` spliced its second argument into a pattern unwrapped, so
  `'\\/'` meant "a backslash followed by a slash" and
  `rtrim('a///', '\\/')` stripped nothing. `includes/server/adapter.lua` makes
  exactly that call on a script directory, so it has never trimmed there.
]]
assert_eq('rtrim_takes_a_character_set', text.rtrim('a///', '\\/'), 'a')
assert_eq('rtrim_returns_one_value', select('#', text.rtrim('a///', '/')), 1)

io.write '\n-- replace --\n'

--[[ The one caller strips CR and LF out of a URL on its way to a `Location`
  header, which is a header-injection defence.
]]
assert_eq('replace_strips_newlines',
  text.replace({'\n', '\r'}, '', 'a\nb\rc'), 'abc')
assert_eq('replace_takes_a_bare_string',
  text.replace('b', 'X', 'abc'), 'aXc')
assert_eq('replace_replaces_every_occurrence',
  text.replace('a', 'X', 'aaa'), 'XXX')
assert_eq('replace_of_nil_is_the_empty_string',
  text.replace({'\n'}, '', nil), '')

--[[ Plain text on both sides. A pattern metacharacter in the needle or a `%` in
  the replacement must not be interpreted, or a defensive scrub becomes
  input-dependent.
]]
assert_eq('replace_needle_is_literal',
  text.replace('.', 'X', 'a.b'), 'aXb')
assert_eq('replace_leaves_other_characters_alone',
  text.replace('.', 'X', 'ab'), 'ab')
assert_eq('replace_keeps_a_literal_percent_in_the_replacement',
  text.replace('a', '100%', 'a'), '100%')
assert_eq('replace_handles_a_percent_needle',
  text.replace('%', '', 'a%b'), 'ab')

--[[ Deliberate divergence 4. Seawolf walked the search list with `pairs`, so
  replacement order was undefined. Order is observable the moment one search
  string can produce another.
]]
assert_eq('replace_applies_searches_in_order',
  text.replace({'ab', 'b'}, 'b', 'ab'), 'b')

io.write(('\n%d passed, %d failed\n'):format(pass_count, fail_count))

if fail_count > 0 then
  os.exit(1)
end
