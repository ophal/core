--[[ What a driver has to provide, and the parts every driver shares.

  A driver is the only place that knows a backend's wire protocol. It declares:

    name              the key in settings, e.g. 'pgmoon'
    dialect           which per-dialect override a statement uses
    placeholder       'numbered' ($1), 'question' (?), or nil (cannot bind)
    connect(config)   a live handle, or nil plus a message
    execute(...)      run a compiled statement, return a result
    release(h, ok)    pool it on success, close it on failure
    quote_identifier  a table or column name, quoted for this backend
    escape(value)     only for a driver that cannot bind

  `dialect` is separate from `name` on purpose. `pgmoon` and
  `luadbi_postgresql` are two drivers over one dialect, so they share every
  compiled statement's overrides -- which is what lets the OpenResty runtime and
  the `lua5.1` CLI reach one database through different drivers without a
  statement being written twice.
]]

local M = {}

local format = string.format

--[[ A Lua number as SQL sees it.

  `tostring` is the wrong tool and this is not theoretical: LuaJIT's `tostring`
  is `%.14g`, so `tostring(123456789012345)` is `1.2345678901234e+14`. pgmoon's
  own `escape_literal` uses it, which means the escaped-literal path -- the
  fastest column in the stage 8.3 table -- silently truncates integers past
  fourteen digits and hands PostgreSQL a float literal. That is the OID 1700
  coercion again by another road: a float compared against an integer column
  coerces the column and no index can serve it.

  Whole numbers therefore go out as integers, and only a real fraction gets
  `%.17g`, which round-trips a double exactly.
]]
function M.number_literal(value)
  if value % 1 == 0 and value >= -9223372036854775808 and value <= 9223372036854775807 then
    return format('%d', value)
  end

  return format('%.17g', value)
end

-- Every driver quotes identifiers the same way once the name is known to be a
-- bare identifier, which the registry has already checked. Backends differ on
-- the quote character, so this takes it.
function M.identifier_quoter(char)
  local closing = char == '`' and '`' or char

  return function(name)
    return char .. name .. closing
  end
end

function M.load(module_name)
  return require('includes.database.driver.' .. module_name)
end

return M
