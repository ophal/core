local M = {}

local time = os.time
local floor = math.floor
local version_cache = {}
local payload_cache = {}
local CACHE_NIL = {}
local DEFAULT_PAYLOAD_CACHE_SIZE = 512

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

local function cache_bucket(projection_key)
  local key = normalize_key(projection_key)
  local bucket = payload_cache[key]

  if not bucket then
    -- `newest` and `oldest` are the ends of an intrusive recency list. Entries
    -- link through `newer` and `older` so promotion and eviction stay O(1)
    -- instead of scanning the bucket on every hit.
    bucket = {entries = {}, count = 0}
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

  rs, err = M.query(
    'SELECT version FROM projection_version WHERE projection_key = ?',
    normalized
  )

  if not rs then
    return nil, err
  end

  row = rs:fetch()
  row = normalize_version(row and row[1] or nil)

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
    payload_cache[normalized] = nil
    if shared then
      shared:set(normalized, current)
    end
    return true
  end

  version_cache[normalized] = current
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
    -- off also releases what it accumulated while it was on.
    payload_cache[normalize_key(projection_key)] = nil

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

    if entry.value == CACHE_NIL then
      return nil
    end

    return entry.value
  end

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

function projection_cache_clear()
  version_cache = {}
  payload_cache = {}
end

return M
