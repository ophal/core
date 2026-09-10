--[[ What a driver has to provide, and the parts every driver shares.

  A driver is the only place that knows a backend's wire protocol. It declares:

    name              the key in settings, e.g. 'pgmoon'
    dialect           which per-dialect override a statement uses
    placeholder       'numbered' ($1), 'question' (?), or nil (cannot bind)
    connect(config)   a live handle, or nil plus a message
    execute(...)      run a compiled statement, return a result
    rows(res)         that result as rows: a list of tables keyed by column
                      name, or something `includes/database/result.lua` can pull
                      rows from. Never a boolean and never nil -- a statement
                      that produced no rows produced an empty list, and the
                      normalising a backend needs (`ngx.null`, a sentinel) is
                      this function's job rather than the call sites'
    release(h, ok)    pool it on success, close it on failure
    quote_identifier  a table or column name, quoted for this backend
    escape(value)     only for a driver that cannot bind

  `dialect` is separate from `name` on purpose: two drivers over one dialect
  share every compiled statement's overrides, so a second binding for a backend
  Ophal already speaks costs no statement being written twice. That once served
  a second *runtime* -- the `lua5.1` CLI reaching PostgreSQL through a blocking
  driver -- and since 2026-09-10 there is one runtime, so what it buys now is a
  second binding rather than a second interpreter.
]]

local M = {}

local format = string.format

-- int8's range. A Lua number outside it, or with a fraction, is not an integer
-- to any of the three backends whatever it looks like in Lua.
local INT8_MIN, INT8_MAX = -9223372036854775808, 9223372036854775807

-- Whether a number is one a backend will take as an integer. Separate from the
-- literal below because pgmoon needs the same answer to pick a type OID rather
-- than to write text.
function M.is_integer(value)
  return value % 1 == 0 and value >= INT8_MIN and value <= INT8_MAX
end

--[[ A Lua number as SQL sees it.

  `tostring` is the wrong tool and this is not theoretical: LuaJIT's `tostring`
  is `%.14g`, so `tostring(123456789012345)` is `1.2345678901234e+14`. pgmoon's
  own `escape_literal` uses it, which means the escaped-literal path -- the
  fastest column in the stage 8.3 table -- silently truncates integers past
  fourteen digits and hands PostgreSQL a float literal. That is the OID 1700
  coercion again by another road: a float compared against an integer column
  coerces the column and no index can serve it.

  Whole numbers therefore go out as integers, and only a real fraction gets
  `%.17g`, which round-trips a double exactly -- `%.14g` loses digits off a
  fraction just as readily as off an integer, it merely does it quietly.
]]
function M.number_literal(value)
  if M.is_integer(value) then
    return format('%d', value)
  end

  return format('%.17g', value)
end

--[[ A table or column name, quoted for a backend.

  The name has already been held to `^[%a_][%w_]*$` by
  `includes/database/registry.lua`, so it cannot carry the quote character and
  there is nothing here to escape -- the validation is what makes this safe, and
  a quoter that took arbitrary text would not be. Backends differ only in the
  character, and every one of them closes with the character it opened with.
]]
function M.identifier_quoter(char)
  return function(name)
    return char .. name .. char
  end
end

function M.load(module_name)
  return require('includes.database.driver.' .. module_name)
end

return M
