--[[ The value and table helpers Ophal actually uses.

  These replace the parts of `seawolf.variable` and `seawolf.contrib` this
  codebase reached for. Most of `seawolf.contrib` was a metatable full of
  methods -- `shift`, `flip`, `keys`, `has`, `dump`, `print`,
  `insert_multiple` -- and Ophal called three of them.

  `empty()` is reproduced exactly rather than improved, for a reason spelled out
  at the function. The other three are small enough that the argument for a
  module at all is that they have surprising behaviour worth stating once.
]]

local M = {}

local type, next, pairs, ipairs = type, next, pairs, ipairs
local tostring, concat, unpack = tostring, table.concat, unpack or table.unpack

--[[ PHP's `empty()`, and it is load-bearing exactly as it stands.

      empty(nil)   true    empty(false) true    empty(0)   true
      empty('')    true    empty('0')   true    empty({})  true
      empty(' ')   false   empty(1)     false   empty({1}) false

  **Do not "fix" the `0` and `'0'` cases.** The sharpest consumer is
  `modules/content`'s `access()`: `if not empty(entity.status) or ...` is what
  keeps an **unpublished** node -- `status` 0 -- from being readable by anyone
  who asks. Make `empty(0)` false and that guard passes for every visitor, in
  the permissive direction, which is the one nothing downstream notices.
  `is_logged_in()` is `not empty(session().user_id)` and reads a session that
  still holds a literal 0 the same way; `modules/user`'s `session_user_id()`
  returns 0 for exactly this reason and says so. `'0'` is the same hazard one
  step out, because a value read back from a MySQL column can be a numeric
  *string*.

  93 call sites across `includes/` and `modules/`. This is a compatibility
  contract, not a design choice.

  `tests/unit/test_util.lua` pins the whole truth table, and it is the **only**
  place that does: dropping a row there turns three assertions red and leaves
  every other suite green, including `test_user_permissions.lua`. The
  unpublished-content guard above has no test of its own -- worth one, and not
  something the row-by-row table can stand in for.

  `next(v)` rather than `#v`, so a table holding only string keys is not empty.
]]
local falses = {
  [false] = true,
  [0] = true,
  [''] = true,
  ['0'] = true,
}

function M.empty(value)
  return not value or falses[value] or
    (type(value) == 'table' and next(value) == nil) or false
end

--[[ Flatten a table of nested tables and strings into one string.

  This is `seawolf.contrib.table_concat`, and it is **not** `table.concat`. It
  walks `pairs` recursively, so it descends into nested tables and reads
  string-keyed values as well as the array part.

  `pager_url()` depends on the descent: it appends `{'?page=', page}` as a
  *table* and only the flatten turns that back into `?page=2`. Plain
  `table.concat` raises on it.

  Two hazards come with that and both are real. It reads **string keys**, which
  is how `roles:concat()` in `modules/user` used to pick up the `anonymous` and
  `authenticated` markers alongside numeric role ids -- see the note there. And
  its order is **`pairs` order**, which is undefined once any non-sequential key
  exists. Neither matters for the two call sites left, both of which build a
  dense array of strings; anything new should ask whether it wants this or
  `table.concat`.
]]
local function flatten(value, out)
  for _, item in pairs(value) do
    if type(item) == 'table' then
      flatten(item, out)
    else
      out[#out + 1] = item
    end
  end
end

function M.concat_deep(value, separator)
  local out = {}

  flatten(value, out)

  return concat(out, separator)
end

--[[ Everything after the first element, as a new table.

  This is `seawolf.contrib.table_shift`, whose name says it mutates and which
  does not: it returns a fresh table and leaves the argument alone. It also goes
  through `unpack`, so it sees **only the array part** and drops every string
  key. `route.lua`'s one call relies on exactly that -- it hands over a route
  record like `{'route_page', module = 'entity'}` and wants neither the callback
  name nor the module.
]]
function M.rest(value)
  local out = {}

  for i = 2, #value do
    out[i - 1] = value[i]
  end

  return out
end

--[[ A readable dump of a value, for `includes/debug.lua`.

  Replaces `seawolf.variable.print_r`, which declared its recursive helper
  **without `local`** and so wrote a global on every call. Cycles are detected
  the way that one did, because a request-state table can reach itself.
]]
local function dump_value(value, name, indent, seen, out)
  local label = name == nil and '' or tostring(name)

  out[#out + 1] = indent .. label .. (name ~= nil and ' = ' or '')

  if type(value) ~= 'table' then
    if type(value) == 'number' or type(value) == 'boolean' then
      out[#out + 1] = tostring(value) .. '\n'
    else
      out[#out + 1] = ('%q'):format(tostring(value)) .. '\n'
    end

    return
  end

  if seen[value] ~= nil then
    out[#out + 1] = ('{} -- %s (self reference)\n'):format(seen[value])
    return
  end

  seen[value] = label

  if next(value) == nil then
    out[#out + 1] = '{}\n'
    return
  end

  out[#out + 1] = '{\n'

  for key, item in pairs(value) do
    dump_value(item, key, indent .. '    ', seen, out)
  end

  out[#out + 1] = indent .. '}\n'
end

function M.dump(value)
  local out = {}

  dump_value(value, nil, '', {}, out)

  return concat(out)
end

return M
