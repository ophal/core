--[[ The user module's statements.

  Declared beside the module rather than in `includes/database/statements.lua`,
  which is the framework's own. `modules/user/init.lua` requires this above its
  `module()` call, the way it captures everything else it needs, because
  `module()` replaces that file's environment.
]]

local registry = require 'includes.database.registry'

local define = registry.define

define('user.set_password', {
  sql = 'UPDATE users SET pass = ? WHERE id = ?',
  tables = {'users'},
})

--[[ Load an account by any column the schema really has.

  The column is an identifier, so it belongs to the compile key: it is validated
  and quoted once per distinct value per worker rather than formatted into SQL
  on every call. The whitelist is not a list kept here to drift -- it is
  `db:field()`, which answers only for a column `information_schema` (or
  SQLite's `pragma_table_info`) reports on this connection's own schema.

  A column the table does not have used to reach `('%s'):format(nil)` and raise
  "bad argument"; it now names the statement, the identifier and the value.
]]
define('user.load_by_field', {
  sql = 'SELECT * FROM users WHERE {field} = ?',
  idents = {
    field = function(value, connection)
      return connection:field('users', value)
    end,
  },
  order = {'field'},
  tables = {'users'},
})

define('user.role_list', {
  sql = 'SELECT id, name FROM role WHERE active = 1 ORDER BY weight, id',
  tables = {'role'},
})

define('user.roles', {
  sql = [[SELECT ur.role_id
FROM user_role ur JOIN role r ON ur.role_id = r.id
WHERE user_id = ?]],
  tables = {'user_role', 'role'},
})

define('user.create', {
  sql = [[INSERT INTO users(name, mail, pass, active, created)
VALUES(?, ?, ?, ?, ?)]],
  tables = {'users'},
})

define('user.create_with_id', {
  sql = [[INSERT INTO users(id, name, mail, pass, active, created)
VALUES(?, ?, ?, ?, ?, ?)]],
  tables = {'users'},
})

define('user.update', {
  sql = [[UPDATE users SET name = ?, mail = ?, pass = ?, active = ?, created = ?
WHERE id = ?]],
  tables = {'users'},
})

return true
