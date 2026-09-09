--[[ Filesystem accounting for the media path.

  Phase 6 exits when media-heavy requests stop dominating worker time through
  synchronous merge and post-processing work. That is a claim about how much
  filesystem work a request does, and until now nothing could state it: the
  smoke suite exercised `file/upload` and `file/merge` but pinned no cost for
  either, so the merge loop could have been reintroduced with every existing
  assertion still green.

  This is the filesystem counterpart of `includes/database/stats.lua`, and it is
  deliberately not global instrumentation. Wrapping every `io.open` in the
  codebase would cost something on paths nobody is measuring. Two paths have a
  budget to hold and both name themselves: `media`, from `modules/file`, and
  `session`, from `includes/session.lua`.

  They are counted in separate buckets for the reason this header used to give
  for having only one caller -- that session traffic would bury the numbers that
  matter. It would: a media request opens a session too, so one set of counters
  would have made every media budget a statement about sessions as well, and
  moving one would have moved the other. `record()` therefore takes the bucket
  and refuses an unknown one, rather than defaulting: a permissive default is
  how a third caller lands in the wrong bucket silently.

  The number that matters most is `bytes` -- how many bytes moved *through Lua*.
  A rename moves a whole file for one syscall and zero bytes; a read-and-write
  merge moves every byte twice and holds a chunk of them in a Lua string. Ops
  alone would rate those the same.
]]

local M = {}

local ipairs, pairs, type = ipairs, pairs, type
local tonumber = tonumber

local enabled
local buckets

local OPS = {'open', 'read', 'write', 'rename', 'remove'}
local BUCKETS = {'media', 'session'}

local function new_counts()
  local fresh = {bytes = 0, files = {}}

  for _, op in ipairs(OPS) do
    fresh[op] = 0
  end

  return fresh
end

local function new_buckets()
  local fresh = {}

  for _, name in ipairs(BUCKETS) do
    fresh[name] = new_counts()
  end

  return fresh
end

buckets = new_buckets()

-- Counting is off unless `settings.performance.fs_stats` is true, so the cost
-- on a normal request is one boolean test per operation. Read once per worker,
-- because settings do not change at runtime.
local function stats_enabled()
  if enabled == nil then
    enabled = (((settings or {}).performance or {}).fs_stats == true)
  end

  return enabled
end

--[[ Record one filesystem operation.

  `bytes` is optional and only meaningful for reads and writes. It is counted
  apart from the operation so that "one write of ten megabytes" and "ten writes
  of one byte" stay distinguishable -- they cost very different things, and a
  budget that only counted calls would call them equal.
]]
function M.record(op, bytes, path, bucket)
  local counts = buckets[bucket]

  if counts == nil then
    error(('fs stats: unknown bucket %q'):format(tostring(bucket)), 2)
  end

  if not stats_enabled() then
    return
  end

  if counts[op] == nil then
    return
  end

  counts[op] = counts[op] + 1
  counts.bytes = counts.bytes + (tonumber(bytes) or 0)

  if path ~= nil then
    counts.files[path] = (counts.files[path] or 0) + 1
  end
end

function M.reset()
  enabled = nil
  buckets = new_buckets()
end

-- The bucket is named at every read too, for the same reason it is named at
-- every write: a budget that does not say which path it describes is a budget
-- that quietly starts describing two.
function M.snapshot(bucket)
  local counts = buckets[bucket]
  local files, snapshot

  if counts == nil then
    error(('fs stats: unknown bucket %q'):format(tostring(bucket)), 2)
  end

  files = {}
  snapshot = {bytes = counts.bytes, files = files}

  for path, count in pairs(counts.files) do
    files[path] = count
  end

  for _, op in ipairs(OPS) do
    snapshot[op] = counts[op]
  end

  return snapshot
end

return M
