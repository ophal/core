#!/usr/bin/env resty
--[[ A tracked file must not point at a path the repository does not carry.

  Ophal keeps its design and planning notes as local working documents that are
  deliberately not committed, and the agent-context files beside them are
  excluded outright. Both are useful locally and invisible to anyone who clones
  -- so a tracked file that links or refers to one is a dangling reference for
  every reader but the person who wrote it.

  That happened five times before this check existed: `README.md` linked three
  planning documents that are not in the repository, `TODO.md` named two of
  them, and `includes/module.lua` quoted an excluded context file twice. The
  links rendered on the forge as ordinary links and 404ed.

  Two mechanisms, because the references take two shapes.

  **A path with a directory component** is checked against the index
  directly. This catches a reference to a file that exists nowhere at all,
  which is the shape a rename or a deletion leaves behind.

  **A bare filename** -- an excluded file at the repository root -- cannot be
  recognised by shape, so the forbidden names are *discovered from git* rather
  than written down here. Writing them down would put the very strings this
  check exists to remove into a tracked file, which is the problem rather than
  the fix. `git status --ignored` knows what is excluded; this asks it.

  Both need git, because the ordinary "does this file exist?" test cannot see
  the problem: these files *do* exist in the working tree of whoever wrote the
  reference. Only the index knows what a clone would receive. The check skips
  itself, loudly, when there is no git metadata -- a source tarball is a
  legitimate way to run the suite and has no index to consult.
]]

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

local function capture(command)
  local pipe = io.popen(command)

  if not pipe then return nil end

  local out = pipe:read('*a')

  pipe:close()

  return out
end

-- --------------------------------------------------------------- the index --

local inside_repo = (capture('git rev-parse --is-inside-work-tree 2>/dev/null') or '')
  :match('true') ~= nil

if not inside_repo then
  io.write('  SKIP repository reference check: no git metadata\n')
  io.write('\n0 passed, 0 failed\n')
  os.exit(0)
end

local tracked, tracked_count = {}, 0

for path in (capture('git ls-files') or ''):gmatch('[^\n]+') do
  tracked[path] = true
  tracked_count = tracked_count + 1
end

--[[ A scanner that reports zero because it is looking at nothing is
  indistinguishable from a clean repository, which is the failure mode every
  lint in this suite guards against explicitly.
]]
assert_eq('the_scan_reached_the_index', tracked_count > 50, true)

-- ------------------------------------------------------ the forbidden names --

--[[ Every documentation file present in the working tree that a clone would not
  receive -- untracked or excluded -- named by its path and by its bare name.

  The vendor tree is skipped: it carries third-party `README.md` files, and a
  basename drawn from one of those would forbid the word `README.md` everywhere.
  The stronger rule is the one below it -- a name that is itself a tracked file
  is never forbidden -- which keeps `README.md` legal however it is discovered.
]]
local forbidden, forbidden_count = {}, 0

for line in (capture('git status --porcelain --ignored --untracked-files=all 2>/dev/null') or ''):gmatch('[^\n]+') do
  local path = line:match('^..%s+(.+)$')

  if path and path:match('%.md$') and not path:match('^tests/smoke/vendor/') then
    for _, name in ipairs({path, path:match('[^/]+$')}) do
      if name and not tracked[name] and not forbidden[name] then
        forbidden[name] = true
        forbidden_count = forbidden_count + 1
      end
    end
  end
end

-- There are such files in this working tree; if there were none, the mechanism
-- below would pass without having looked at anything.
assert_eq('the_scan_found_excluded_documents', forbidden_count > 0, true)
assert_eq('a_tracked_name_is_never_forbidden', forbidden['README.md'], nil)

-- ------------------------------------------------------------- the scanner --

local function referenced_paths(text)
  local found = {}

  --[[ A forge URL pinned to a ref carries a repository-relative path, and that
    path is what matters: a blob URL resolves to the repository-relative path
    after the ref, and 404s if the repository does not carry it. So the prefix
    is stripped and the remainder is checked like any other reference. This
    branch exists because the check's own first run reported the release link
    in `README.md` as a dangling reference.

    No example path is spelled out here, in this file or any other: an
    illustrative `docs/whatever` in a comment is itself a reference to
    something the repository does not carry, and this file exempts itself from
    the scan, so nothing else would catch it. Two such examples survived the
    first history rewrite and had to be removed in a second pass.
  ]]
  text = text:gsub('https?://[^%s)]-/blob/[^/%s]+/', '')

  -- Anything else with a scheme points outside the repository and is not this
  -- check's business.
  text = text:gsub('https?://%S+', '')

  for path in text:gmatch('[%w_.%-]+/[%w_./%-]+%.md') do
    found[path] = true
  end

  return found, text
end

--[[ This file is the one exemption, and it is narrow: the assertions below
  plant synthetic references in order to prove the scanner reacts to them, so
  scanning this file would report its own fixtures. It names no real excluded
  file -- that is the whole point of discovering them from git -- so the
  exemption hides nothing.
]]
local SELF = 'tests/unit/test_repo_references.lua'

local offences, offence_count, scanned = {}, 0, 0

for path in pairs(tracked) do
  local is_text = path:match('%.md$') or path:match('%.lua$')
    or path:match('%.sh$') or path:match('%.conf$') or path:match('%.txt$')

  if is_text and path ~= SELF and not path:match('^tests/smoke/vendor/') then
    local handle = io.open(path, 'r')

    if handle then
      local body = handle:read('*a')

      handle:close()
      scanned = scanned + 1

      local paths, stripped = referenced_paths(body)

      for reference in pairs(paths) do
        if not tracked[reference] then
          offence_count = offence_count + 1
          offences[#offences + 1] = ('%s -> %s'):format(path, reference)
        end
      end

      for name in pairs(forbidden) do
        if stripped:find(name, 1, true) then
          offence_count = offence_count + 1
          offences[#offences + 1] = ('%s -> %s'):format(path, name)
        end
      end
    end
  end
end

assert_eq('the_scan_reached_the_files', scanned > 20, true)

if offence_count > 0 then
  table.sort(offences)
  io.write('\n  tracked files referencing paths the repository does not carry:\n')
  for _, line in ipairs(offences) do
    io.write(('    %s\n'):format(line))
  end
  io.write('\n')
end

assert_eq('no_tracked_file_references_an_untracked_path', offence_count, 0)

-- ------------------------------------------------------- the scanner itself --

-- Driven both ways against planted text, so a green result above means the
-- scanner works rather than that it is quiet.
do
  local absent = 'docs/' .. 'not-a-real-plan' .. '.md'

  assert_eq('scanner_finds_a_markdown_link',
    referenced_paths(('see [the plan](%s) for more'):format(absent))[absent], true)

  assert_eq('scanner_ignores_a_bare_tracked_name',
    referenced_paths('see README.md')['README.md'], nil)

  -- A forge link pinned to a tag resolves to the repository path it carries, so
  -- a link to a tracked file is not an offence and a link to an absent one is.
  assert_eq('scanner_resolves_a_forge_blob_link',
    referenced_paths(('<https://example.com/o/r/blob/v1/%s>'):format(absent))[absent],
    true)

  assert_eq('scanner_ignores_an_external_url',
    referenced_paths('see https://example.com/manual/intro.md for more')
      ['example.com/manual/intro.md'],
    nil)

  -- And the bare-name mechanism, against a name taken from git rather than
  -- written here.
  local sample

  for name in pairs(forbidden) do
    if not name:find('/') then sample = name break end
  end

  if sample then
    local _, stripped = referenced_paths(('as recorded in `%s` today'):format(sample))

    assert_eq('scanner_finds_a_forbidden_bare_name',
      stripped:find(sample, 1, true) ~= nil, true)
  else
    assert_eq('scanner_finds_a_forbidden_bare_name', 'no bare excluded name to test', 'skipped')
  end
end

io.write(('\n%d passed, %d failed\n'):format(pass_count, fail_count))

if fail_count > 0 then
  os.exit(1)
end
