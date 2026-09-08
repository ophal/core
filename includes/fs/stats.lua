--[[ Filesystem accounting for the media path.

  Phase 6 exits when media-heavy requests stop dominating worker time through
  synchronous merge and post-processing work. That is a claim about how much
  filesystem work a request does, and until now nothing could state it: the
  smoke suite exercised `file/upload` and `file/merge` but pinned no cost for
  either, so the merge loop could have been reintroduced with every existing
  assertion still green.

  This is the filesystem counterpart of `includes/database/stats.lua`, and it is
  deliberately not global instrumentation. Only the media path calls through it,
  because that is the only path with a budget to hold. Wrapping every `io.open`
  in the codebase would cost something on paths nobody is measuring and would
  bury the numbers that matter in template and session traffic.

  The number that matters most is `bytes` -- how many bytes moved *through Lua*.
  A rename moves a whole file for one syscall and zero bytes; a read-and-write
  merge moves every byte twice and holds a chunk of them in a Lua string. Ops
  alone would rate those the same.
]]

local M = {}

local ipairs, pairs, type = ipairs, pairs, type
local tonumber = tonumber

local enabled
local counts

local OPS = {'open', 'read', 'write', 'rename', 'remove'}

local function new_counts()
  local fresh = {bytes = 0, files = {}}

  for _, op in ipairs(OPS) do
    fresh[op] = 0
  end

  return fresh
end

counts = new_counts()

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
function M.record(op, bytes, path)
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
  counts = new_counts()
end

function M.snapshot()
  local files = {}
  local snapshot = {bytes = counts.bytes, files = files}

  for path, count in pairs(counts.files) do
    files[path] = count
  end

  for _, op in ipairs(OPS) do
    snapshot[op] = counts[op]
  end

  return snapshot
end

return M
