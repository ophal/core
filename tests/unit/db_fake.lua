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

function M.connection(dispatch)
  local conn = {}

  function conn:run(name, ...)
    local decl = registry.declaration(name)

    if decl == nil then
      error('undeclared statement: ' .. tostring(name), 0)
    end

    if dispatch.statement then
      return dispatch.statement(name, ...)
    end

    return dispatch.sql(decl.sql, ...)
  end

  --[[ A statement whose identifiers are fixed.

    The real one memoizes a compiled statement per distinct identifier value;
    this substitutes them into the declared body so a SQL-dispatching stand-in
    sees the statement the call site actually means.
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

        return dispatch.sql(M.substitute(decl, values, conn), ...)
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

-- The declared body with its `{ident}` slots filled in, unquoted: a stand-in
-- matches on the name it would see in real SQL, not on the dialect's quoting.
function M.substitute(decl, values, connection)
  return (decl.sql:gsub('{(%w+)(:?%a*)}', function(key)
    local resolver = decl.idents and decl.idents[key]
    local value = values[key]

    if type(resolver) == 'function' then
      value = resolver(value, connection)
    end

    if value == nil then
      error(('%s needs identifier %q'):format(decl.name, key), 0)
    end

    return tostring(value)
  end))
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
