local M = {}

local time = os.time

local function normalize_key(key)
  return tostring(key or '')
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
  local rs, err = M.query(
    'SELECT version FROM projection_version WHERE projection_key = ?',
    normalize_key(key)
  )
  local row

  if not rs then
    return nil, err
  end

  row = rs:fetch()
  return row and row[1] or nil
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
  local current = tonumber(version) or time()
  local ok, err = M.exec(
    'DELETE FROM projection_version WHERE projection_key = ?',
    normalize_key(key)
  )

  if not ok then
    if M.is_missing_table(err, 'projection_version') then
      return true
    end

    return nil, err
  end

  ok, err = M.exec(
    'INSERT INTO projection_version(projection_key, version, updated_at) VALUES(?, ?, ?)',
    normalize_key(key),
    current,
    time()
  )

  if not ok and M.is_missing_table(err, 'projection_version') then
    return true
  end

  return ok, err
end

return M
