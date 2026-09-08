--[[ The content module's statements: the normalized table and its projection.

  `content` is the source an author edits; `content_public` is what a visitor's
  page is rendered from. Both are declared here so the two shapes of the front
  page -- an anonymous visitor sees published rows, a signed-in one sees all of
  them -- are two statements rather than one body with a WHERE fragment
  formatted into it on every request.

  That fragment was `('... %s ORDER BY created DESC' .. db_limit()):format(query)`
  at the call site, which built a string and re-derived the dialect's LIMIT
  spelling per request. `{{limit}}` is the dialect fragment now, expanded once
  per driver at compile time: PostgreSQL spells it `OFFSET ? LIMIT ?` and SQLite
  and MySQL `LIMIT ?, ?`, and both take (offset, count) in that order, which is
  why one parameter order serves every dialect.
]]

local registry = require 'includes.database.registry'

local define = registry.define

define('content.load', {
  sql = 'SELECT * FROM content WHERE id = ?',
  tables = {'content'},
})

define('content.all', {
  sql = 'SELECT * FROM content',
  tables = {'content'},
})

define('content.create', {
  sql = [[INSERT INTO content(user_id, title, teaser, body, status, promote, created)
VALUES(?, ?, ?, ?, ?, ?, ?)]],
  tables = {'content'},
})

define('content.create_with_id', {
  sql = [[INSERT INTO content(id, user_id, title, teaser, body, status, promote, created)
VALUES(?, ?, ?, ?, ?, ?, ?, ?)]],
  tables = {'content'},
})

define('content.update', {
  sql = [[UPDATE content SET title = ?, teaser = ?, body = ?, status = ?,
  promote = ?, changed = ?
WHERE id = ?]],
  tables = {'content'},
})

define('content.delete', {
  sql = 'DELETE FROM content WHERE id = ?',
  tables = {'content'},
})

-- The normalized fallback for the front page, in its two scopes.
define('content.frontpage_count_all', {
  sql = 'SELECT count(*) AS total FROM content WHERE promote = 1',
  tables = {'content'},
})

define('content.frontpage_count_published', {
  sql = 'SELECT count(*) AS total FROM content WHERE promote = 1 AND status = 1',
  tables = {'content'},
})

define('content.frontpage_rows_all', {
  sql = [[SELECT * FROM content WHERE promote = 1
ORDER BY created DESC{{limit}}]],
  tables = {'content'},
})

define('content.frontpage_rows_published', {
  sql = [[SELECT * FROM content WHERE promote = 1 AND status = 1
ORDER BY created DESC{{limit}}]],
  tables = {'content'},
})

-- ------------------------------------------------------ the projection ----

define('content.public_load', {
  sql = 'SELECT * FROM content_public WHERE id = ?',
  tables = {'content_public'},
})

define('content.public_insert', {
  sql = [[INSERT INTO content_public(
  id, user_id, language, title, teaser, body,
  created, changed, status, promote, route, updated_at
) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)]],
  tables = {'content_public'},
})

define('content.public_delete', {
  sql = 'DELETE FROM content_public WHERE id = ?',
  tables = {'content_public'},
})

define('content.public_clear', {
  sql = 'DELETE FROM content_public',
  tables = {'content_public'},
})

define('content.public_count_all', {
  sql = 'SELECT count(*) AS total FROM content_public WHERE promote = 1',
  tables = {'content_public'},
})

define('content.public_count_published', {
  sql = [[SELECT count(*) AS total FROM content_public
WHERE promote = 1 AND status = 1]],
  tables = {'content_public'},
})

define('content.public_rows_all', {
  sql = [[SELECT * FROM content_public WHERE promote = 1
ORDER BY created DESC{{limit}}]],
  tables = {'content_public'},
})

define('content.public_rows_published', {
  sql = [[SELECT * FROM content_public WHERE promote = 1 AND status = 1
ORDER BY created DESC{{limit}}]],
  tables = {'content_public'},
})

return true
