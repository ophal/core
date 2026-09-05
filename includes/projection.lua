local M = {}

local time = os.time
local version_cache = {}
local payload_cache = {}
local CACHE_NIL = {}

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

local function cache_bucket(projection_key)
  local key = normalize_key(projection_key)

  payload_cache[key] = payload_cache[key] or {}
  return payload_cache[key]
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
  local bucket
  local entry
  local value, err

  if projection_version == nil then
    projection_version, err = M.version(projection_key)
    if err ~= nil then
      return nil, err
    end
  end

  bucket = cache_bucket(projection_key)
  entry = bucket[normalize_key(cache_key)]
  if entry and entry.version == projection_version then
    if entry.value == CACHE_NIL then
      return nil
    end

    return entry.value
  end

  value, err = loader(projection_version)
  if err ~= nil then
    return nil, err
  end

  bucket[normalize_key(cache_key)] = {
    version = projection_version,
    value = value == nil and CACHE_NIL or value,
  }

  return value
end

function projection_cache_clear()
  version_cache = {}
  payload_cache = {}
end

return M
