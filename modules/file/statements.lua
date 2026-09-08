--[[ The file module's statements. ]]

local registry = require 'includes.database.registry'

local define = registry.define

--[[ Load a file row by any column the schema really has.

  The column is an identifier and so part of the compile key: validated and
  quoted once per distinct value per worker rather than formatted into SQL on
  every call. The whitelist is `db:field()`, which answers from this
  connection's own schema, so it cannot drift from the database.
]]
define('file.load_by_field', {
  sql = 'SELECT * FROM file WHERE {field} = ?',
  idents = {
    field = function(value, connection)
      return connection:field('file', value)
    end,
  },
  order = {'field'},
  tables = {'file'},
})

define('file.create', {
  sql = [[INSERT INTO file(user_id, filename, filepath, filemime, filesize, status, timestamp)
VALUES(?, ?, ?, ?, ?, ?, ?)]],
  tables = {'file'},
})

define('file.create_with_id', {
  sql = [[INSERT INTO file(id, user_id, filename, filepath, filemime, filesize, status, timestamp)
VALUES(?, ?, ?, ?, ?, ?, ?, ?)]],
  tables = {'file'},
})

define('file.update', {
  sql = [[UPDATE file SET user_id = ?, filename = ?, filepath = ?, filemime = ?,
  filesize = ?, status = ?, timestamp = ?
WHERE id = ?]],
  tables = {'file'},
})

define('file.delete', {
  sql = 'DELETE FROM file WHERE id = ?',
  tables = {'file'},
})

return true
