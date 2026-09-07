local M = {}

local time = os.time
local floor = math.floor
local version_cache = {}
local version_miss = {}
local payload_cache = {}
local CACHE_NIL = {}
local DEFAULT_PAYLOAD_CACHE_SIZE = 512
local DEFAULT_VERSION_MISS_TTL = 5
local CACHE_EVENTS = {'hits', 'misses', 'stale', 'evictions'}
local cache_stats_on
local cache_counts = {}

local function normalize_key(key)
  return tostring(key or '')
end

local function normalize_version(value)
  if value == nil then
    return nil
  end

  return tonumber(value) or value
end

local function shared_versions_dict()
  local shared
  local performance = (settings or {}).performance or {}
  local dict_name = performance.projection_shared_dict or 'ophal_projection_versions'

  if not ngx or type(ngx.shared) ~= 'table' then
    return nil
  end

  shared = ngx.shared[dict_name]
  if shared and type(shared.get) == 'function' and type(shared.set) == 'function' then
    return shared
  end
end

-- The payload cache lives in worker memory and is only dropped wholesale by a
-- version change or `cache_clear_all()`, so an unbounded cache grows for the
-- life of the worker. Each projection gets its own LRU bucket; projection keys
-- come from code rather than from request input, so bounding each bucket also
-- bounds the total. A size of 0 disables payload caching entirely.
local function payload_cache_limit()
  local performance = (settings or {}).performance or {}
  local limit = tonumber(performance.projection_payload_cache_size)

  -- `limit ~= limit` is the NaN test.
  if limit == nil or limit ~= limit or limit < 0 then
    return DEFAULT_PAYLOAD_CACHE_SIZE
  end

  return floor(limit)
end

-- Payload cache accounting. The bound is configurable, but nothing reported
-- whether the size a site chose is the right one for it, and the two ways a
-- lookup can fail want opposite answers: absent keys alongside evictions mean
-- the bucket is too small, while stale keys mean writes are moving the version
-- faster than reads get to use what was cached. Raising the size fixes the
-- first and does nothing at all for the second, so they are counted apart.
--
-- Counting is off unless `settings.performance.projection_cache_stats` is true,
-- which leaves one boolean test per lookup on a normal request. The setting is
-- read once per worker, the way the query classifier reads its own.
local function cache_stats_enabled()
  if cache_stats_on == nil then
    cache_stats_on = (((settings or {}).performance or {}).projection_cache_stats == true)
  end

  return cache_stats_on
end

local function record_cache(projection_key, event)
  local key, counts

  if not cache_stats_enabled() then
    return
  end

  key = normalize_key(projection_key)
  counts = cache_counts[key]

  if not counts then
    counts = {hits = 0, misses = 0, stale = 0, evictions = 0}
    cache_counts[key] = counts
  end

  counts[event] = counts[event] + 1
end

-- A projection with no version row is a miss the L1 table cannot represent:
-- storing nil is indistinguishable from storing nothing, so `version()` fell
-- through to SQL on every call for the whole life of the worker. That is the
-- ordinary case for a source key nothing has touched yet, which put one
-- `projection_version` round trip on every anonymous page. Misses are recorded
-- separately instead, and they expire.
--
-- The TTL is what keeps the negative cache honest. A version row can appear
-- from outside the web workers -- a CLI migration, a cron rebuild -- and those
-- processes have no shared zone to publish into, so nothing would tell this
-- worker to look again. A TTL of 0 disables miss caching.
local function version_miss_ttl()
  local performance = (settings or {}).performance or {}
  local ttl = tonumber(performance.projection_version_miss_ttl)

  -- `ttl ~= ttl` is the NaN test.
  if ttl == nil or ttl ~= ttl or ttl < 0 then
    return DEFAULT_VERSION_MISS_TTL
  end

  return floor(ttl)
end

local function cache_bucket(projection_key)
  local key = normalize_key(projection_key)
  local bucket = payload_cache[key]

  if not bucket then
    -- `newest` and `oldest` are the ends of an intrusive recency list. Entries
    -- link through `newer` and `older` so promotion and eviction stay O(1)
    -- instead of scanning the bucket on every hit.
    bucket = {key = key, entries = {}, count = 0}
    payload_cache[key] = bucket
  end

  return bucket
end

local function lru_unlink(bucket, entry)
  if entry.newer then
    entry.newer.older = entry.older
  else
    bucket.newest = entry.older
  end

  if entry.older then
    entry.older.newer = entry.newer
  else
    bucket.oldest = entry.newer
  end

  entry.newer, entry.older = nil, nil
end

local function lru_link(bucket, entry)
  entry.older = bucket.newest
  entry.newer = nil

  if bucket.newest then
    bucket.newest.newer = entry
  end

  bucket.newest = entry
  bucket.oldest = bucket.oldest or entry
end

local function lru_promote(bucket, entry)
  if bucket.newest == entry then
    return
  end

  lru_unlink(bucket, entry)
  lru_link(bucket, entry)
end

local function lru_evict(bucket, limit)
  while bucket.count > limit do
    local oldest = bucket.oldest

    if not oldest then
      bucket.count = 0
      return
    end

    lru_unlink(bucket, oldest)
    bucket.entries[oldest.key] = nil
    bucket.count = bucket.count - 1
    record_cache(bucket.key, 'evictions')
  end
end

function M.query(query, ...)
  local ok, result = pcall(db_query, query, ...)
  if not ok then
    return nil, result
  end

  return result
end

function M.exec(query, ...)
  return M.query(query, ...)
end

function M.is_missing_table(err, table_name)
  local message = tostring(err or '')
  local escaped = table_name and table_name:gsub('([^%w])', '%%%1') or nil

  if escaped and message:match('no such table:%s*' .. escaped) then
    return true
  end

  if escaped and message:match('relation "?'
      .. escaped .. '"? does not exist') then
    return true
  end

  return false
end

function M.version(key)
  local normalized = normalize_key(key)
  local shared = shared_versions_dict()
  local cached = version_cache[normalized]
  local shared_value
  local rs, err
  local row

  -- Answer from cache before touching SQL. Querying first would keep the
  -- per-request database round trip that these caches exist to remove.
  if shared then
    shared_value = normalize_version(shared:get(normalized))
    if shared_value ~= nil then
      version_cache[normalized] = shared_value
      return shared_value
    end
  elseif cached ~= nil then
    return cached
  end

  -- A remembered miss short-circuits the same round trip. With a shared zone
  -- the peer worker publishes on touch(), so this stays correct there too.
  if (version_miss[normalized] or 0) > time() then
    return nil
  end

  rs, err = M.query(
    'SELECT version FROM projection_version WHERE projection_key = ?',
    normalized
  )

  if not rs then
    return nil, err
  end

  row = rs:fetch()
  row = normalize_version(row and row[1] or nil)

  if row == nil then
    version_miss[normalized] = time() + version_miss_ttl()
  else
    version_miss[normalized] = nil
  end

  version_cache[normalized] = row
  if shared and row ~= nil then
    shared:set(normalized, row)
  end

  return row
end

function M.max_version(keys)
  local latest

  for _, key in ipairs(keys or {}) do
    local version, err = M.version(key)

    if version == nil then
      if err and not M.is_missing_table(err, 'projection_version') then
        return nil, err
      end
    else
      version = tonumber(version) or version
      if latest == nil or version > latest then
        latest = version
      end
    end
  end

  return latest
end

function M.ensure(key, rebuild, options)
  local current, err = M.version(key)
  local latest_dependency

  options = options or {}

  if current == nil then
    if err and not M.is_missing_table(err, 'projection_version') then
      return nil, err
    end
  else
    current = tonumber(current) or current
  end

  latest_dependency, err = M.max_version(options.depends_on)
  if err then
    return nil, err
  end

  if current ~= nil and (latest_dependency == nil or current >= latest_dependency) then
    return true
  end

  if type(rebuild) ~= 'function' then
    return nil, ('projection rebuild is unavailable for %s'):format(normalize_key(key))
  end

  return rebuild()
end

-- Dropping `payload_cache[normalized]` here is not redundant with the version
-- comparison in `cached_value()`, and removing it as dead weight serves stale
-- pages. Versions have one-second granularity, so a write landing in the same
-- second a reader cached its entry leaves `entry.version` equal to the version
-- it is compared against, and the entry reads as fresh. Clearing the bucket is
-- what makes a write visible to a reader inside its own second; the comparison
-- is what covers every later one. `db_content_page_after_update` in the smoke
-- suite fails on a stale title if this line goes away.
function M.touch(key, version)
  local normalized = normalize_key(key)
  local current = tonumber(version) or time()
  local shared = shared_versions_dict()
  local ok, err = M.exec(
    'DELETE FROM projection_version WHERE projection_key = ?',
    normalized
  )

  if not ok then
    if M.is_missing_table(err, 'projection_version') then
      version_cache[normalized] = current
      version_miss[normalized] = nil
      payload_cache[normalized] = nil
      if shared then
        shared:set(normalized, current)
      end
      return true
    end

    return nil, err
  end

  ok, err = M.exec(
    'INSERT INTO projection_version(projection_key, version, updated_at) VALUES(?, ?, ?)',
    normalized,
    current,
    time()
  )

  if not ok and M.is_missing_table(err, 'projection_version') then
    version_cache[normalized] = current
    version_miss[normalized] = nil
    payload_cache[normalized] = nil
    if shared then
      shared:set(normalized, current)
    end
    return true
  end

  version_cache[normalized] = current
  version_miss[normalized] = nil
  payload_cache[normalized] = nil
  if shared then
    shared:set(normalized, current)
  end

  return ok, err
end

function M.cached_value(projection_key, cache_key, loader, options)
  local projection_version = options and options.version
  local limit = payload_cache_limit()
  local key = normalize_key(cache_key)
  local bucket
  local entry
  local value, err

  if projection_version == nil then
    projection_version, err = M.version(projection_key)
    if err ~= nil then
      return nil, err
    end
  end

  if limit < 1 then
    -- Caching is off. Drop anything the bucket still holds so turning the cache
    -- off also releases what it accumulated while it was on. The load still
    -- counts as a miss, so hits plus misses plus stale stays the number of
    -- lookups and a disabled cache reads as the zero hit rate it is.
    payload_cache[normalize_key(projection_key)] = nil
    record_cache(projection_key, 'misses')

    value, err = loader(projection_version)
    if err ~= nil then
      return nil, err
    end

    return value
  end

  bucket = cache_bucket(projection_key)
  entry = bucket.entries[key]
  if entry and entry.version == projection_version then
    lru_promote(bucket, entry)
    record_cache(projection_key, 'hits')

    if entry.value == CACHE_NIL then
      return nil
    end

    return entry.value
  end

  record_cache(projection_key, entry and 'stale' or 'misses')

  value, err = loader(projection_version)
  if err ~= nil then
    return nil, err
  end

  if entry then
    entry.version = projection_version
    entry.value = value == nil and CACHE_NIL or value
    lru_promote(bucket, entry)
  else
    entry = {
      key = key,
      version = projection_version,
      value = value == nil and CACHE_NIL or value,
    }
    bucket.entries[key] = entry
    bucket.count = bucket.count + 1
    lru_link(bucket, entry)
  end

  lru_evict(bucket, limit)

  return value
end

-- What the counters say about this worker, rolled up and broken out per
-- projection. Occupancy is reported whether or not counting is on, because
-- bucket sizes are maintained either way and `entries` against `limit` is the
-- first thing worth knowing about a bucket.
function M.cache_stats()
  local snapshot = {
    hits = 0,
    misses = 0,
    stale = 0,
    evictions = 0,
    entries = 0,
    limit = payload_cache_limit(),
    projections = {},
  }

  local function projection_row(key)
    local row = snapshot.projections[key]

    if not row then
      row = {hits = 0, misses = 0, stale = 0, evictions = 0, entries = 0}
      snapshot.projections[key] = row
    end

    return row
  end

  for key, counts in pairs(cache_counts) do
    local row = projection_row(key)

    for _, event in ipairs(CACHE_EVENTS) do
      row[event] = counts[event]
      snapshot[event] = snapshot[event] + counts[event]
    end
  end

  -- Both sides are walked because neither covers the other: a bucket can hold
  -- entries with no counts beside them when counting was turned on after it
  -- filled, and counts outlive their bucket, since a version change or
  -- `cache_clear_all()` drops the payload and not the evidence for it.
  for key, bucket in pairs(payload_cache) do
    projection_row(key).entries = bucket.count
    snapshot.entries = snapshot.entries + bucket.count
  end

  return snapshot
end

-- Deliberately not called by `projection_cache_clear()`: dropping the payloads
-- is a normal consequence of a write, and it would take the measurement with it.
function M.cache_stats_reset()
  cache_stats_on = nil
  cache_counts = {}
end

function projection_cache_clear()
  version_cache = {}
  version_miss = {}
  payload_cache = {}
end

return M
