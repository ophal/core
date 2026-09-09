-- Unit tests for includes/fs/stats.lua: the filesystem accounting the media
-- path's smoke budgets are stated in terms of.
--
-- The counters are what let `db_media_merge` assert that reassembling an
-- 11-byte file moves 22 bytes through Lua. If they lie, that budget stops
-- meaning anything, so the gate, the bytes arithmetic and the reset are pinned
-- here rather than only through the smoke suite.

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

local function load_stats(performance)
  package.loaded['includes.fs.stats'] = nil
  _G.settings = {performance = performance}
  return require 'includes.fs.stats'
end

io.write '\n-- filesystem accounting --\n'

do
  local stats = load_stats{fs_stats = true}
  local snapshot

  stats.record('open', nil, '/tmp/a', 'media')
  stats.record('write', 8, '/tmp/a', 'media')
  stats.record('write', 3, '/tmp/a', 'media')
  stats.record('read', 11, '/tmp/a', 'media')
  stats.record('remove', nil, '/tmp/a', 'media')
  stats.record('rename', nil, nil, 'media')

  snapshot = stats.snapshot('media')

  assert_eq('fs_counts_opens', snapshot.open, 1)
  assert_eq('fs_counts_writes', snapshot.write, 2)
  assert_eq('fs_counts_reads', snapshot.read, 1)
  assert_eq('fs_counts_removes', snapshot.remove, 1)
  assert_eq('fs_counts_renames', snapshot.rename, 1)

  -- Bytes accumulate across operations and across both directions. A copy shows
  -- up as twice the size of the file, which is the whole point of counting them
  -- apart from the calls: a rename and a read-then-write of the same file are
  -- one operation each way but nothing like the same cost.
  assert_eq('fs_counts_bytes', snapshot.bytes, 22)

  -- Five of the six operations above named that path; the rename named none,
  -- which is the case that must not raise or invent a key.
  assert_eq('fs_counts_per_file', snapshot.files['/tmp/a'], 5)
end

-- The snapshot must be a copy. It is read by a probe that then keeps counting,
-- and a shared table would let the reader mutate what it is measuring.
do
  local stats = load_stats{fs_stats = true}
  local first, second

  stats.record('write', 5, '/tmp/b', 'media')
  first = stats.snapshot('media')
  stats.record('write', 5, '/tmp/b', 'media')
  second = stats.snapshot('media')

  assert_eq('fs_snapshot_is_a_copy', first.bytes, 5)
  assert_eq('fs_snapshot_moves_on', second.bytes, 10)
  first.files['/tmp/b'] = 999
  assert_eq('fs_snapshot_files_is_a_copy', stats.snapshot('media').files['/tmp/b'], 2)
end

-- Off by default, and off is genuinely off: nothing is counted and nothing is
-- allocated per operation. This is the same gate `query_stats` uses, for the
-- same reason -- the accounting exists for the test suite, not for production.
do
  local stats = load_stats{}

  stats.record('open', nil, '/tmp/c', 'media')
  stats.record('write', 100, '/tmp/c', 'media')

  assert_eq('fs_disabled_counts_nothing', stats.snapshot('media').open, 0)
  assert_eq('fs_disabled_counts_no_bytes', stats.snapshot('media').bytes, 0)
  assert_eq('fs_disabled_records_no_file', stats.snapshot('media').files['/tmp/c'], nil)
end

do
  local stats = load_stats{}

  assert_eq('fs_absent_settings_off', stats.snapshot('media').open, 0)
end

-- An unknown op is ignored rather than counted into a field of its own. The
-- snapshot's shape is what the smoke helper reads by name, so a typo at a call
-- site must not silently invent a counter nothing asserts on.
do
  local stats = load_stats{fs_stats = true}

  stats.record('fsync', 10, '/tmp/d', 'media')

  assert_eq('fs_unknown_op_ignored', stats.snapshot('media').bytes, 0)
  assert_eq('fs_unknown_op_no_file', stats.snapshot('media').files['/tmp/d'], nil)
end

-- `reset()` drops the gate too, so a test that changes the setting sees the
-- change. Without that the first read of `settings` would stick for the life of
-- the worker and every later block here would measure the first block's gate.
do
  local stats = load_stats{fs_stats = true}

  stats.record('write', 7, '/tmp/e', 'media')
  assert_eq('fs_reset_before', stats.snapshot('media').bytes, 7)

  settings.performance = {fs_stats = false}
  stats.reset()
  stats.record('write', 7, '/tmp/e', 'media')

  assert_eq('fs_reset_clears_counts', stats.snapshot('media').bytes, 0)
  assert_eq('fs_reset_rereads_the_gate', stats.snapshot('media').write, 0)
end

io.write '\n-- the buckets are separate --\n'

--[[ A media request opens a session too.

  One set of counters would therefore have made every media budget a statement
  about sessions as well: the media scenarios in `db_profile.sh` went red the
  moment `includes/session.lua` started recording, which is how this came up.
  Moving one path's cost would have moved the other's, and the media numbers are
  the ones Phase 6 pinned.
]]
do
  local stats = load_stats{fs_stats = true}

  stats.record('open', nil, '/tmp/m', 'media')
  stats.record('write', 10, '/tmp/m', 'media')
  stats.record('open', nil, '/tmp/s', 'session')
  stats.record('write', 100, '/tmp/s', 'session')
  stats.record('remove', nil, '/tmp/s', 'session')

  assert_eq('fs_media_counts_only_media', stats.snapshot('media').open, 1)
  assert_eq('fs_media_bytes_only_media', stats.snapshot('media').bytes, 10)
  assert_eq('fs_media_sees_no_session_file',
    stats.snapshot('media').files['/tmp/s'], nil)
  assert_eq('fs_session_counts_only_session', stats.snapshot('session').open, 1)
  assert_eq('fs_session_bytes_only_session', stats.snapshot('session').bytes, 100)
  assert_eq('fs_session_counts_removes', stats.snapshot('session').remove, 1)
  assert_eq('fs_session_sees_no_media_file',
    stats.snapshot('session').files['/tmp/m'], nil)
end

--[[ An unknown bucket raises rather than defaulting.

  A permissive default is how a third caller lands in the wrong bucket silently,
  and a bucket that silently absorbs another path's work is exactly the failure
  the split exists to prevent. It raises whether or not counting is enabled --
  a name that is wrong is wrong on a production site too, where the gate is off.
]]
do
  local stats = load_stats{fs_stats = true}
  local off = load_stats{}

  assert_eq('fs_unknown_bucket_raises',
    pcall(stats.record, 'open', nil, '/tmp/x', 'templates'), false)
  assert_eq('fs_missing_bucket_raises',
    pcall(stats.record, 'open', nil, '/tmp/x'), false)
  assert_eq('fs_unknown_bucket_raises_when_disabled',
    pcall(off.record, 'open', nil, '/tmp/x', 'templates'), false)
  assert_eq('fs_unknown_snapshot_raises',
    pcall(stats.snapshot, 'templates'), false)
end

io.write(('\n%d passed, %d failed\n'):format(pass_count, fail_count))

if fail_count > 0 then
  os.exit(1)
end
