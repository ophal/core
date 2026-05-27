local M = {}

local Result = {}
Result.__index = Result

local function normalize_named(named)
  if named then
    return true
  end
end

local function is_wrapper(value)
  return getmetatable(value) == Result
end

local function raw_fetch(raw, named)
  if type(raw.fetch) == 'function' then
    return raw:fetch(normalize_named(named))
  elseif type(raw.fetch_one) == 'function' then
    return raw:fetch_one(named and true or false)
  end

  error('database result does not implement fetch semantics')
end

function Result:fetch(named)
  return raw_fetch(self._raw, named)
end

function Result:rows(named)
  if type(self._raw.fetch) == 'function'
      or type(self._raw.fetch_one) == 'function' then
    return function()
      return self:fetch(named)
    end
  elseif type(self._raw.rows) == 'function' then
    return self._raw:rows(normalize_named(named))
  end

  error('database result does not implement row iteration semantics')
end

function Result:all(named)
  local items = {}

  for row in self:rows(named) do
    items[#items + 1] = row
  end

  return items
end

function Result:close()
  if type(self._raw.close) == 'function' then
    return self._raw:close()
  end

  return true
end

function Result:raw()
  return self._raw
end

function M.wrap(raw)
  if raw == nil then
    return nil
  elseif is_wrapper(raw) then
    return raw
  end

  return setmetatable({_raw = raw}, Result)
end

M.Result = Result

return M
