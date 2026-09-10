--[[ Path helpers, beside `includes/fs/stats.lua`.

  These replace `seawolf.fs`'s path half and `seawolf.behaviour.temp_dir`. The
  other half of `seawolf.fs` -- `safe_open`, `safe_write`, `safe_close` -- is
  replaced by `includes/session/store.lua`, and between them they are what let
  **LuaSocket and luuid leave the dependency list**: `seawolf/fs/init.lua`'s
  third line is

      local package, sleep, uuid = package, require 'socket'.sleep, require 'uuid'

  a load-time require, so anything that reached for `dirname()` dragged both in.

  `dirname` and `basename` keep seawolf's answers exactly, including the one
  that is not POSIX -- see below. `is_file` and `is_dir` do not: seawolf's
  `is_file` tested the *error* rather than the value, and both passed a nil path
  straight into `lfs.attributes`, which raises rather than answering.
]]

local M = {}

local lfs = require 'lfs'
local getenv, gsub, sub, type = os.getenv, string.gsub, string.sub, type

-- `package.config`'s first character, per src/loadlib.c.
local SEPARATOR = sub(package.config, 1, 1)

--[[ The directory part of a path.

  **`dirname('/index.lua')` is `''`, not `'/'`.** POSIX `dirname` answers `/`;
  seawolf answered the empty string, and three call sites are built on that --
  `server_normalize_path()` subtracts its length from a request path, and
  `build_base()` trims it to decide whether Ophal is mounted in a subdirectory.
  Answering `/` here would take a character off every path.
]]
function M.dirname(path)
  path = tostring(path or '')
  path = gsub(path, SEPARATOR .. '$', '')

  local base = M.basename(path)

  return sub(path, 1, #path - #base - 1)
end

--[[ The final component of a path. ]]
function M.basename(path)
  return (gsub(tostring(path or ''),
    '[^' .. SEPARATOR .. ']*' .. SEPARATOR, ''))
end

--[[ Whether `path` is an existing regular file.

  Tests the *value* `lfs.attributes` returns, not the error beside it. Seawolf's
  was `err == nil and file.mode == 'file'`, which indexes nil and raises on any
  build where a miss answers `nil` with no message -- and `is_dir` right below
  it already tested the value, so the two disagreed about how to ask the same
  question.
]]
local function attributes_of(path)
  -- `lfs.attributes` raises "bad argument #1 (string expected, got nil)"
  -- rather than answering, and seawolf's helpers passed that straight through.
  -- A predicate that raises instead of answering false is one every caller has
  -- to guard, so guard it once here.
  if type(path) ~= 'string' or path == '' then
    return nil
  end

  return lfs.attributes(path)
end

function M.is_file(path)
  local attributes = attributes_of(path)

  return attributes ~= nil and attributes.mode == 'file'
end

--[[ Whether `path` is an existing directory. ]]
function M.is_dir(path)
  local attributes = attributes_of(path)

  return attributes ~= nil and attributes.mode == 'directory'
end

--[[ The directory for temporary files, with **no trailing separator**.

  Memoized for the life of the worker, as seawolf's was. Under OpenResty
  `os.getenv` only sees what nginx's `env` directive declares, so in a worker
  this reliably answers `/tmp` whatever the shell had.
]]
local temp

function M.temp_dir()
  if temp == nil then
    temp = getenv 'TMP' or getenv 'TEMP' or getenv 'TMPDIR' or '/tmp'
  end

  return temp
end

return M
