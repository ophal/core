--[[ The SQL surface: what a call site is allowed to hand the database.

  Stage 8.5 moved 63 call sites onto declared statements and 8.6 removed the two
  that could not be declared, and the audit that drove both found its hits with
  a throwaway scanner. This is that scanner kept, which is the difference
  between "we fixed the bugs we found" and "you cannot write that bug here".

  Three rules, each one a shape that was actually wrong in this codebase:

  - **A SQL literal carrying a format slot.** `modules/user` built its
    permission read as `IN ('%s')` over the account's role ids, and the probe
    shows a hostile id returning the canary from a WHERE clause written to match
    nothing, on all three backends.
  - **SQL assembled with `..`.** `modules/tag` concatenated one UNION arm per
    entity type. That one was not exploitable -- the types were held to
    `^[%a_][%w_]*$` by hand -- but it is the same shape, and the hand-rolled
    check was a second copy of a guard the registry already owns.
  - **`db:execute()` outside the allowlist.** The layer keeps a raw path for
    migrations and the CLI. Every ORM ships one of these too, and it is where
    injection lives in ORM-backed applications; what makes it safe here is that
    there is exactly one caller and a test that fails when a second appears.

  The scan is literal-aware rather than line-based, and that is not a detail.
  The audit's first pass grepped lines beginning with `SELECT` and reported the
  surface clean -- it missed the injectable IN list because the `%s` sat on a
  different line from the verb. Comments are masked for the same reason: this
  file, `modules/tag` and `includes/database/connection.lua` all discuss
  `db:execute()` in prose, and a scanner that reads prose is a scanner someone
  turns off.
]]

package.path = './?.lua;./?/init.lua;' .. package.path

local passed, failed = 0, 0

local function assert_eq(name, actual, expected)
  if actual == expected then
    passed = passed + 1
    io.write(('  ok %s\n'):format(name))
  else
    failed = failed + 1
    io.write(('  FAIL %s: expected %s, got %s\n'):format(
      name, tostring(expected), tostring(actual)))
  end
end

--[[ Files exempt from a rule, each for a stated reason.

  Kept deliberately short. An allowlist that grows is the lint failing rather
  than the code passing, so a new entry wants the same argument these two carry:
  no request input can reach this SQL, and the shape genuinely cannot be
  declared.
]]
local ALLOW = {
  -- Migrations and the CLI. The DDL comes from `includes/migrations.lua`, the
  -- table and column names from the migration being applied, and nothing on
  -- this path is reachable from a request -- `ophal migrate apply` is run by a
  -- human or by cron. Its arity varies per migration, which is the same reason
  -- the two statements 8.6 closed were ad-hoc.
  ['includes/migrate.lua'] = {format = true, concat = true, execute = true},
}

-- ---------------------------------------------------------------- the scanner

local function long_open(src, i)
  if src:sub(i, i) ~= '[' then
    return nil
  end

  local j = i + 1

  while src:sub(j, j) == '=' do
    j = j + 1
  end

  if src:sub(j, j) == '[' then
    return j - i - 1, j + 1
  end
end

--[[ Walk Lua source, returning every string literal and a masked copy.

  The mask keeps the source's byte and line positions but blanks comment bodies
  and string *contents*, so a pattern run over it cannot match anything a human
  wrote as prose or as data. That is what makes the `:execute(` rule safe to
  state as a substring search.
]]
local function read_source(src)
  local literals, mask = {}, {}
  local i, line, n = 1, 1, #src

  local function blank(from, to)
    for k = from, to do
      mask[k] = src:sub(k, k) == '\n' and '\n' or ' '
    end
  end

  local function keep(from, to)
    for k = from, to do
      mask[k] = src:sub(k, k)
    end
  end

  while i <= n do
    local c = src:sub(i, i)

    if c == '-' and src:sub(i + 1, i + 1) == '-' then
      local level, after = long_open(src, i + 2)
      local stop

      if level then
        local close = ']' .. ('='):rep(level) .. ']'
        local e = src:find(close, after, true)

        stop = e and (e + #close - 1) or n
      else
        stop = (src:find('\n', i, true) or n + 1) - 1
      end

      blank(i, stop)

      for _ in src:sub(i, stop):gmatch('\n') do
        line = line + 1
      end

      i = stop + 1
    elseif c == '"' or c == "'" then
      local j, buf = i + 1, {}

      while j <= n do
        local d = src:sub(j, j)

        if d == '\\' then
          buf[#buf + 1] = src:sub(j + 1, j + 1)
          j = j + 2
        elseif d == c or d == '\n' then
          break
        else
          buf[#buf + 1] = d
          j = j + 1
        end
      end

      literals[#literals + 1] =
        {text = table.concat(buf), line = line, start = i, stop = j}
      keep(i, i)
      blank(i + 1, j - 1)
      keep(j, j)
      i = j + 1
    else
      local level, after = long_open(src, i)

      if level then
        local close = ']' .. ('='):rep(level) .. ']'
        local e = src:find(close, after, true)
        local stop = e and (e + #close - 1) or n
        local body = src:sub(after, (e or n + 1) - 1)

        literals[#literals + 1] =
          {text = body, line = line, start = i, stop = stop}
        blank(i, stop)

        for _ in body:gmatch('\n') do
          line = line + 1
        end

        i = stop + 1
      else
        keep(i, i)

        if c == '\n' then
          line = line + 1
        end

        i = i + 1
      end
    end
  end

  return literals, table.concat(mask)
end

local STRONG = {
  'SELECT', 'INSERT', 'UPDATE', 'DELETE', 'CREATE', 'ALTER', 'DROP', 'TRUNCATE',
}
local WEAK = {'FROM', 'WHERE', 'INTO', 'VALUES', 'SET', 'TABLE', 'JOIN'}

local function has_word(text, word)
  return text:find('%f[%w]' .. word .. '%f[%W]') ~= nil
end

--[[ Whether a literal is SQL.

  Two indicators rather than one, because a bare `'update'` is an action name in
  half this codebase and `'set'` is a Lua idiom. A fragment carrying FROM and
  WHERE counts on its own: fragments are exactly what concatenation produces,
  and `' FROM content WHERE id = '` has no verb in it at all.
]]
local function is_sql(text)
  local up = text:upper()
  local strong, weak = false, false

  for _, word in ipairs(STRONG) do
    if has_word(up, word) then
      strong = true
      break
    end
  end

  for _, word in ipairs(WEAK) do
    if has_word(up, word) then
      weak = true
      break
    end
  end

  if strong and weak then
    return true
  end

  return has_word(up, 'FROM') and has_word(up, 'WHERE')
end

local function line_of(src, pos)
  local line = 1

  for _ in src:sub(1, pos):gmatch('\n') do
    line = line + 1
  end

  return line
end

local function findings(path, src)
  local literals, mask = read_source(src)
  local allow = ALLOW[path] or {}
  local out = {}

  for _, literal in ipairs(literals) do
    if is_sql(literal.text) then
      local before = src:sub(1, literal.start - 1)
      local after = src:sub(literal.stop + 1)

      -- `%q` too: it quotes for Lua, not for SQL, and reads as though it were
      -- doing the safe thing.
      if not allow.format and literal.text:find('%%[sdqiu]') then
        out[#out + 1] = {
          rule = 'format', path = path, line = literal.line,
          text = literal.text,
        }
      end

      if not allow.concat and
        (before:match('%.%.%s*$') or after:match('^%s*%.%.')) then
        out[#out + 1] = {
          rule = 'concat', path = path, line = literal.line,
          text = literal.text,
        }
      end
    end
  end

  if not allow.execute then
    local at = 1

    while true do
      local s, e = mask:find(':execute%s*%(', at)

      if s == nil then
        break
      end

      -- The method's own definition is not a caller. Written as a check rather
      -- than an allowlist entry so that `includes/database/connection.lua` is
      -- still linted for everything else.
      if not mask:sub(1, s - 1):match('function%s+[%w_.:]*$') then
        out[#out + 1] = {rule = 'execute', path = path, line = line_of(src, s)}
      end

      at = e + 1
    end
  end

  return out
end

-- ------------------------------------------------------------- the lint tests

io.write '\n-- the scanner, against planted code --\n'

--[[ A lint nobody has seen fail is a lint that reports zero because it is
  broken. Each rule is driven here on source built to trip it, and on source
  built to look like it should and not.
]]
local function count(src, rule)
  local n = 0

  for _, finding in ipairs(findings('fixture.lua', src)) do
    if rule == nil or finding.rule == rule then
      n = n + 1
    end
  end

  return n
end

assert_eq('catches_a_concatenated_statement',
  count([[local sql = 'SELECT id FROM content WHERE id = ' .. id]], 'concat'), 1)

assert_eq('catches_concatenation_on_the_left',
  count([[local sql = prefix .. ' FROM content WHERE id = 1']], 'concat'), 1)

assert_eq('catches_a_format_slot',
  count([[db:execute(('SELECT * FROM %s WHERE id = ?'):format(t))]], 'format'), 1)

assert_eq('catches_a_numeric_format_slot',
  count([[local sql = 'SELECT * FROM content WHERE id = %d']], 'format'), 1)

--[[ The shape that was actually injectable, restated.

  `modules/user`'s permission read, with the `%s` on a different line from the
  verb -- which is exactly why the audit's line-based grep called the surface
  clean and missed it.
]]
assert_eq('catches_the_in_list_that_was_injectable', count([[
local sql = [==[SELECT permission
FROM role_permission
WHERE role_id IN ('%s')]==]
]], 'format'), 1)

assert_eq('catches_an_execute_caller',
  count([[local rs = db_connection():execute(sql, id)]], 'execute'), 1)

io.write '\n-- and what it must not catch --\n'

assert_eq('declared_statement_is_clean',
  count([[define('content.load', {sql = 'SELECT * FROM content WHERE id = ?'})]]), 0)

assert_eq('a_long_bracket_declaration_is_clean', count([[
define('user.role_permissions', {sql = [==[SELECT permission
FROM role_permission
WHERE role_id IN (?*)]==]})
]]), 0)

-- This file, `modules/tag` and `connection.lua` all discuss `db:execute()` in
-- prose. A scanner that reads comments is one somebody turns off.
assert_eq('prose_about_execute_is_clean',
  count([[-- the two db:execute() calls were the last SQL text]], 'execute'), 0)

assert_eq('prose_in_a_long_comment_is_clean', count([[
--[==[ This mentions db:execute() and 'SELECT * FROM %s WHERE x = 1' too. ]==]
local x = 1
]]), 0)

assert_eq('the_method_definition_is_not_a_caller',
  count([[function Connection:execute(sql, ...) end]], 'execute'), 0)

-- A format slot in something that is not SQL is none of this lint's business.
assert_eq('a_non_sql_format_string_is_clean',
  count([[local msg = ('no such user: %s'):format(name)]]), 0)

-- `update` and `set` are ordinary words in this codebase.
assert_eq('an_action_name_is_not_sql',
  count([[if action == 'update' then set_thing() end]]), 0)

-- Concatenation of something that is not SQL is ordinary Lua.
assert_eq('concatenating_a_route_is_clean',
  count([[local path = 'tag/' .. tag.id]]), 0)

io.write '\n-- the codebase --\n'

--[[ The scan itself. `includes/` and `modules/`, every file, no sampling.

  Reported per finding rather than as a count, because the useful output when
  this goes red is the line that did it.
]]
do
  local files, hits, seen = {}, {}, 0
  local pipe = io.popen('find includes modules -name "*.lua" | sort')

  for path in pipe:lines() do
    files[#files + 1] = path
  end

  pipe:close()

  for _, path in ipairs(files) do
    local handle = io.open(path)
    local src = handle:read('*a')

    handle:close()

    for _, literal in ipairs((read_source(src))) do
      if is_sql(literal.text) then
        seen = seen + 1
      end
    end

    for _, finding in ipairs(findings(path, src)) do
      hits[#hits + 1] = finding
      io.write(('  -> %s %s:%d %s\n'):format(
        finding.rule, finding.path, finding.line,
        (finding.text or ''):sub(1, 50)))
    end
  end

  -- A scan that found no SQL at all would report a clean surface for the wrong
  -- reason, and that is the failure mode of every lint written this way.
  assert_eq('the_scan_reached_the_codebase', #files > 40 and seen > 80, true)
  assert_eq('no_sql_is_built_from_text', #hits, 0)
end

io.write(('\n%d passed, %d failed\n'):format(passed, failed))

if failed > 0 then
  os.exit(1)
end
