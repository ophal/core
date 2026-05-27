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
