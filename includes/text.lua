--[[ The string helpers Ophal actually uses, over Lua patterns.

  These replace `seawolf.text`, which was a PHP-compatibility layer and reached
  for LPeg to do it. `explode` built a **fresh LPeg grammar on every call** --
  `lpeg.P`, `lpeg.C` and `lpeg.Ct` per invocation -- and `trim` ran
  `require 'lpeg'` inside its own body. Every request pays for three of those:
  the query string, the cookie header and the route path. Measured 2026-09-10:
  28,589 ns a request through seawolf against 1,924 ns here, and LPeg was a
  required dependency for nothing else.

  What is *not* changed is the semantics the request path already depends on.
  `split` keeps empty fields, because `route_arg()` splits the request path with
  it and a trailing slash has to produce a trailing empty argument the way it
  always did. Those cases are pinned in `tests/unit/test_text.lua` against
  values measured from seawolf before it was removed, not against what looks
  reasonable.

  Four things here deliberately do **not** match seawolf, each because
  seawolf's behaviour was a bug rather than a contract. They are called out at
  each function.
]]

local M = {}

local concat, format, gsub, gmatch = table.concat, string.format, string.gsub, string.gmatch
local type, tostring, ipairs = type, tostring, ipairs

--[[ A Lua pattern character class from a list of characters to strip.

  The characters callers pass are punctuation -- `/`, `\`, `,` -- and `%` is
  Lua's pattern escape, so every one of them is escaped rather than trusted. A
  charlist is a *set of characters*, never a pattern: that is the whole
  difference between this and what seawolf's `ltrim` and `rtrim` did.
]]
local function char_class(charlist)
  if charlist == nil then
    return '%s'
  end

  return (gsub(tostring(charlist), '(.)', '%%%1'))
end

--[[ Split `s` on the literal `delimiter`, keeping empty fields.

  Empty fields are the contract, not an accident:

      split('/', 'a/b/c')    -> {'a', 'b', 'c'}
      split('/', 'a/b/')     -> {'a', 'b', ''}
      split('/', '/a')       -> {'', 'a'}
      split('/', '')         -> {''}
      split('&', 'a=1&&b=2') -> {'a=1', '', 'b=2'}

  A `gmatch('[^/]+')` drops all of them, which would quietly change what
  `route_arg()` answers for any path with a trailing or doubled slash. The
  trailing delimiter appended below is what makes the last field appear.

  The delimiter is one literal character in every call site Ophal has. It is
  escaped into the class rather than interpolated raw, so a delimiter that
  happens to be a pattern metacharacter cannot turn this into a different split.
]]
function M.split(delimiter, s)
  local class = char_class(delimiter)
  local out, n = {}, 0

  for piece in gmatch(tostring(s or '') .. delimiter, '([^' .. class .. ']*)' .. class) do
    n = n + 1
    out[n] = piece
  end

  return out
end

--[[ Strip `charlist` (default whitespace) from both ends.

  **The default set is Lua's `%s`**, which is `\t\n\v\f\r` and a space.
  Seawolf's was `' \t\n\r\0\v'` -- it counted a **NUL** as whitespace and
  missed a form feed. Dropping NUL from the set is the deliberate half: a NUL is
  not whitespace, and silently trimming one turns a value that a downstream
  check would have rejected into one it accepts. `safe_path_segment()` in
  `includes/security.lua` rejects NUL on purpose, and a helper that quietly
  removes it first is working against that.
]]
function M.trim(s, charlist)
  local class = char_class(charlist)

  return (gsub(tostring(s or ''), '^[' .. class .. ']*(.-)[' .. class .. ']*$', '%1'))
end

--[[ Strip `charlist` from the front.

  **One return value.** Seawolf's was `return str:gsub(...)`, which leaks
  `gsub`'s replacement count as a second value -- so `ltrim(x, '/')` in an
  argument list silently became two arguments. Its one call site concatenated
  the result, which truncated it back to one, so nothing had noticed.
]]
function M.ltrim(s, charlist)
  local class = char_class(charlist)

  return (gsub(tostring(s or ''), '^[' .. class .. ']*', ''))
end

--[[ Strip `charlist` from the end.

  **A character set, not a pattern.** Seawolf's `rtrim` spliced its second
  argument into a pattern *unwrapped*, so a multi-character argument matched as
  a sequence rather than a set: `rtrim('a///', '\\/')` asked for "a backslash
  followed by a slash" and stripped nothing at all. That is exactly the call
  `includes/server/adapter.lua` makes on a script directory, so it has never
  trimmed anything there. It is harmless today because `dirname('/index.lua')`
  is already `''`, and it would not have been the moment Ophal was mounted in a
  subdirectory.
]]
function M.rtrim(s, charlist)
  local class = char_class(charlist)

  return (gsub(tostring(s or ''), '[' .. class .. ']*$', ''))
end

--[[ Replace every occurrence of each `search` string with `replacement`.

  Plain text on both sides -- no patterns -- because the one caller is
  `go_to()`, stripping CR and LF out of a URL before it becomes a `Location`
  header. That is a header-injection defence and it should not depend on whether
  a caller's string happens to hold a `%`.

  **`ipairs`, not `pairs`.** Seawolf walked the search list with `pairs`, so
  replacement order was undefined. It did not matter for the one call site,
  where both searches map to the empty string, but undefined order inside a
  security scrub is not worth carrying forward.
]]
function M.replace(search, replacement, s)
  local out = tostring(s or '')

  if type(search) ~= 'table' then
    search = {search}
  end

  replacement = tostring(replacement or '')

  for _, needle in ipairs(search) do
    local escaped = gsub(tostring(needle), '(%W)', '%%%1')

    out = gsub(out, escaped, (gsub(replacement, '%%', '%%%%')))
  end

  return out
end

return M
