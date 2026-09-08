--[[ The comment module's statements. ]]

local registry = require 'includes.database.registry'

local define = registry.define

define('comment.load', {
  sql = 'SELECT * FROM comment WHERE id = ?',
  tables = {'comment'},
})

-- The column is an identifier, held to what `db:field()` reports for this
-- connection's own schema; see `modules/file/statements.lua`.
define('comment.load_by_field', {
  sql = 'SELECT * FROM comment WHERE {field} = ?',
  idents = {
    field = function(value, connection)
      return connection:field('comment', value)
    end,
  },
  order = {'field'},
  tables = {'comment'},
})

define('comment.create', {
  sql = [[INSERT INTO comment(entity_id, parent_id, user_id, language, body, created, status, sticky)
VALUES(?, ?, ?, ?, ?, ?, ?, ?)]],
  tables = {'comment'},
})

define('comment.create_with_id', {
  sql = [[INSERT INTO comment(id, entity_id, parent_id, user_id, language, body, created, status, sticky)
VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?)]],
  tables = {'comment'},
})

define('comment.update', {
  sql = 'UPDATE comment SET body = ?, status = ?, changed = ? WHERE id = ?',
  tables = {'comment'},
})

return true
