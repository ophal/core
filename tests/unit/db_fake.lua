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

local unpack = unpack or table.unpack

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

--[[ Whitespace collapsed, so a stand-in matches a statement and not its layout.

  A declaration is written to be read -- wrapped at a sensible width, one clause
  per line -- and a backend does not care. A stub keyed on the exact text would
  turn every reformatting into a silent no-match that answers no rows, which is
  the least useful way for a test to fail. Runs of whitespace inside a SQL
  string literal would be collapsed too; no statement in the codebase has one.
]]
local function normalize(sql)
  return (sql:gsub('%s+', ' '))
end

function M.connection(dispatch)
  local conn = {}

  function conn:run(name, ...)
    if registry.declaration(name) == nil then
      error('undeclared statement: ' .. tostring(name), 0)
    end

    if dispatch.statement then
      return dispatch.statement(name, ...)
    end

    return dispatch.sql(normalize(registry.compile(DRIVER, name).sql), ...)
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
          normalize(registry.compile(DRIVER, name, values, conn).sql), ...)
      end,
    }
  end

  --[[ A declared statement whose width the caller decides.

    Compiled at the arity the call passes, so a SQL-dispatching stand-in sees
    the expanded `IN (?, ?, ?)` a backend would rather than the `?*` the
    declaration carries -- which is what lets a test assert the placeholder
    count as well as the values.
  ]]
  function conn:list(name, values)
    local decl = registry.declaration(name)

    if decl == nil then
      error('undeclared statement: ' .. tostring(name), 0)
    end

    if type(values) ~= 'table' then
      error('db:list takes a list of values', 0)
    end

    if dispatch.statement then
      return dispatch.statement(name, unpack(values, 1, #values))
    end

    return dispatch.sql(
      normalize(registry.compile(DRIVER, name, nil, conn, #values).sql),
      unpack(values, 1, #values))
  end

  function conn:try(name, ...)
    local ok, result = pcall(self.run, self, name, ...)

    if not ok then
      return nil, result
    end

    return result
  end

  --[[ Ad-hoc SQL: migrations, the installer, and the two statements whose
    arity is not known until they run.

    Compiled the same way a declaration is, so `{{limit}}` is expanded here as
    well and a stand-in sees what a backend would.
  ]]
  function conn:execute(sql, ...)
    return dispatch.sql(normalize(registry.compile_text(DRIVER, sql).sql), ...)
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
