--[[ The entity module's statements: the two that name a table at runtime.

  Both are the `db:with()` case. An entity type and a relation table are
  identifiers, so they belong to the compile key -- validated and rendered once
  per distinct value per worker -- rather than being concatenated into SQL on
  every delete, which is what `'DELETE FROM ' .. entity.type` did.

  The relation names are composed inside the declaration with `:bare`, so the
  convention `rel_<type>_<parent>` is stated once, where it can be read, instead
  of being formatted at the call site. A composed name has no correct quoting --
  `rel_"content"_"tag"` is not a table -- which is why bare is the right
  rendering here and why the guard has to carry the whole weight.

  That guard is a schema lookup, and it needs to be, because the value is not
  the framework's own. It arrives in the URL: `entity/delete/<type>/<id>` is
  parsed by `parse_route_args()` and `entity.type` becomes the table a DELETE
  names. `modules/entity` does check it against the registered entity types
  before it gets here, and that check is right where it is -- only the module
  knows what an entity type is. But the layer cannot see that check, and a
  declaration whose safety lives in its callers is one refactor away from having
  none, so it states its own: the name has to be a table this database actually
  has.

  One limit, stated rather than hidden. The resolver validates the *parts* of a
  composed name, not the name it composes, so `content` and `tag` can both
  resolve while `rel_content_tag` does not exist. That is a SQL error, not an
  injection -- neither part can carry a quote, a comment or a semicolon past
  `^[%a_][%w_]*$` -- and resolving the composition would mean a second
  resolver mechanism for the sake of one declaration.
]]

local registry = require 'includes.database.registry'

local define = registry.define

-- Shared by both declarations: the identifier must name a table this
-- connection's database has. `connection:table()` answers from
-- `core.table_schema`, cached per table, so a `{table}` here and a `{field}` in
-- `load_by_field` on the same table cost one schema read between them.
local function a_table(value, connection)
  return connection:table(value)
end

define('entity.delete', {
  sql = 'DELETE FROM {table} WHERE id = ?',
  idents = {table = a_table},
  order = {'table'},
  tables = {'{table}'},
})

define('entity.delete_relation', {
  sql = 'DELETE FROM rel_{table:bare}_{parent:bare} WHERE {table:bare}_id = ?',
  idents = {table = a_table, parent = a_table},
  order = {'table', 'parent'},
  tables = {'rel_{table:bare}_{parent:bare}'},
})

return true
