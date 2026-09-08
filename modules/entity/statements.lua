--[[ The entity module's statements: the two that name a table at runtime.

  Both are the `db:with()` case. An entity type and a relation table are
  identifiers, so they belong to the compile key -- validated and rendered once
  per distinct value per worker -- rather than being concatenated into SQL on
  every delete, which is what `'DELETE FROM ' .. entity.type` did.

  The relation names are composed inside the declaration with `:bare`, so the
  convention `rel_<type>_<parent>` is stated once, where it can be read, instead
  of being formatted at the call site. Bare is safe here and only here because
  the registry has already held each value to `^[%a_][%w_]*$`: a name that
  matches that cannot carry a quote, a comment or a semicolon. The check is the
  safety property; the quoting would only be the correctness one, and a
  composed name has no correct quoting -- `rel_"content"_"tag"` is not a table.
]]

local registry = require 'includes.database.registry'

local define = registry.define

define('entity.delete', {
  sql = 'DELETE FROM {table} WHERE id = ?',
  idents = {table = true},
  order = {'table'},
  tables = {'{table}'},
})

define('entity.delete_relation', {
  sql = 'DELETE FROM rel_{table:bare}_{parent:bare} WHERE {table:bare}_id = ?',
  idents = {table = true, parent = true},
  order = {'table', 'parent'},
  tables = {'rel_{table:bare}_{parent:bare}'},
})

return true
