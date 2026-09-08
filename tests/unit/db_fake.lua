--[[ A connection object for the unit suite.

  Every call site reaches the database through `db_connection()` now, so a test
  that used to install a `db_query` function installs one of these instead.

  Two dispatches are available and a test picks whichever describes it:

  - `sql(text, ...)` answers the statement's *body*. `run(name, ...)` resolves
    the name through the real registry first, so a suite whose stand-in is
    written in SQL keeps working and gains a check it did not have -- a
    statement that is renamed, or whose body is rewritten, either still matches
    the stand-in or the test says so.
  - `statement(name, ...)` answers the *name*, for a module whose statements
    differ by a clause rather than by a table. Telling `jobs.complete`,
    `jobs.retry` and `jobs.give_up` apart by pattern-matching three UPDATEs is
    exactly the brittleness declarations exist to remove.

  An undeclared name raises either way, so a fake cannot quietly answer a
  statement the registry does not have.
]]

local M = {}

local registry = require 'includes.database.registry'

require 'includes.database.statements'

--[[ The driver a stand-in compiles for.

  Compiling rather than reading `decl.sql` is what makes the SQL a stub sees the
  SQL a backend would: `{{limit}}` is expanded, `{ident}` slots are filled, and
  a declaration that does not compile fails here rather than on the one backend
  that reaches it. Identifiers are left unquoted, because a stand-in matches on
  the name in the statement and not on a dialect's quoting.
]]
local DRIVER = {
  name = 'fake',
  dialect = 'sqlite3',
  placeholder = 'question',
  quote_identifier = function(name) return name end,
  limit_clause = ' LIMIT ?, ?',
}

function M.connection(dispatch)
  local conn = {}

  function conn:run(name, ...)
    if registry.declaration(name) == nil then
      error('undeclared statement: ' .. tostring(name), 0)
    end

    if dispatch.statement then
      return dispatch.statement(name, ...)
    end

    return dispatch.sql(registry.compile(DRIVER, name).sql, ...)
  end

  --[[ A statement whose identifiers are fixed.

    The real one memoizes a compiled statement per distinct identifier value;
    this compiles it the same way, so a SQL-dispatching stand-in sees the
    statement the call site actually means.
  ]]
  function conn:with(name, ...)
    local decl = registry.declaration(name)
    local values = {}

    if decl == nil then
      error('undeclared statement: ' .. tostring(name), 0)
    end

    for i, key in ipairs(decl.order or {}) do
      values[key] = (select(i, ...))
    end

    return {
      run = function(_, ...)
        if dispatch.statement then
          return dispatch.statement(name, ...)
        end

        return dispatch.sql(
          registry.compile(DRIVER, name, values, conn).sql, ...)
      end,
    }
  end

  function conn:try(name, ...)
    local ok, result = pcall(self.run, self, name, ...)

    if not ok then
      return nil, result
    end

    return result
  end

  -- Ad-hoc SQL: migrations, the installer, and the one permission read whose
  -- IN list is as wide as the account has roles.
  function conn:execute(sql, ...)
    return dispatch.sql(sql, ...)
  end

  --[[ `db:field()` is the identifier whitelist.

    The real one answers from `information_schema` and caches per connection.
    A test supplies `field` when it wants to drive a rejection; the default
    accepts, which is what a schema that really has the column would do.
  ]]
  function conn:field(table_name, field_name)
    if dispatch.field then
      return dispatch.field(table_name, field_name)
    end

    return field_name
  end

  function conn:last_insert_id(table_name, field_name)
    if dispatch.last_insert_id then
      return dispatch.last_insert_id(table_name, field_name)
    end

    return 1
  end

  function conn:transaction(fn)
    return fn(self)
  end

  function conn:name()
    return 'default'
  end

  function conn:driver()
    return 'fake'
  end

  function conn:dialect()
    return 'sqlite3'
  end

  function conn:release()
    return true
  end

  return conn
end

--[[ Install one fake as both shapes, on every environment that needs it.

  `db_query` is the transitional free function and `db_connection()` the
  accessor. They must be the same fake, or a test measuring queries would count
  only half of them.
]]
function M.install(dispatch, ...)
  local connection = M.connection(dispatch)
  local accessor = function() return connection end

  for i = 1, select('#', ...) do
    local target = (select(i, ...))

    target.db_query = dispatch.sql
    target.db_connection = accessor
  end

  return connection
end

return M
