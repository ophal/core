--[[ The tag module's statements.

  Three tables: `tag` and `field_tag` are the normalized source, and
  `tag_listing_index` is the projection a tag page and the tags menu are served
  from. The menu renders on every page, so it is the most frequent read of the
  whole projection.

  Two pairs below differ only by `AND ft.tag_id = ?`. They are separate
  declarations rather than one body with a clause appended, because a statement
  assembled per call is a statement compiled per call -- and the pair is what
  `tag_projection_rebuild()` uses to rebuild either one tag or all of them.
]]

local registry = require 'includes.database.registry'

local define = registry.define

define('tag.load', {
  sql = 'SELECT * FROM tag WHERE id = ?',
  tables = {'tag'},
})

define('tag.all', {
  sql = 'SELECT * FROM tag ORDER BY name',
  tables = {'tag'},
})

define('tag.create', {
  sql = [[INSERT INTO tag(user_id, name, description, created, status)
VALUES(?, ?, ?, ?, ?)]],
  tables = {'tag'},
})

define('tag.create_with_id', {
  sql = [[INSERT INTO tag(id, user_id, name, description, created, status)
VALUES(?, ?, ?, ?, ?, ?)]],
  tables = {'tag'},
})

define('tag.update', {
  sql = [[UPDATE tag SET name = ?, description = ?, changed = ?, status = ?
WHERE id = ?]],
  tables = {'tag'},
})

define('tag.delete', {
  sql = 'DELETE FROM tag WHERE id = ?',
  tables = {'tag'},
})

-- ------------------------------------------------------- the relations ----

define('tag.entity_tags', {
  sql = [[SELECT t.* FROM field_tag ft JOIN tag t ON t.id = ft.tag_id
WHERE ft.entity_type = ? AND ft.entity_id = ?]],
  tables = {'field_tag', 'tag'},
})

define('tag.entity_tag_ids', {
  sql = 'SELECT tag_id id FROM field_tag WHERE entity_type = ? AND entity_id = ?',
  tables = {'field_tag'},
})

define('tag.entity_types', {
  sql = [[SELECT entity_type FROM field_tag WHERE tag_id = ?
GROUP BY entity_type]],
  tables = {'field_tag'},
})

define('tag.link', {
  sql = 'INSERT INTO field_tag(entity_type, entity_id, tag_id) VALUES(?, ?, ?)',
  tables = {'field_tag'},
})

define('tag.unlink', {
  sql = [[DELETE FROM field_tag
WHERE entity_type = ? AND entity_id = ? AND tag_id = ?]],
  tables = {'field_tag'},
})

define('tag.unlink_entity', {
  sql = 'DELETE FROM field_tag WHERE entity_type = ? AND entity_id = ?',
  tables = {'field_tag'},
})

define('tag.unlink_tag', {
  sql = 'DELETE FROM field_tag WHERE tag_id = ?',
  tables = {'field_tag'},
})

-- ----------------------------------------------------------- the menus ----

define('tag.menu', {
  sql = [[SELECT t.id, t.name
FROM tag t JOIN field_tag ft ON t.id = ft.tag_id
WHERE t.status = 1
GROUP BY t.id
ORDER BY t.name]],
  tables = {'tag', 'field_tag'},
})

define('tag.entity_menu', {
  sql = [[SELECT t.id, t.name
FROM tag t JOIN field_tag ft ON t.id = ft.tag_id
WHERE ft.entity_type = ? AND ft.entity_id = ? AND t.status = 1
GROUP BY t.id
ORDER BY t.name]],
  tables = {'tag', 'field_tag'},
})

-- ------------------------------------------------------ the projection ----

define('tag.listing_menu', {
  sql = [[SELECT tag_id id, tag_name name
FROM tag_listing_index
GROUP BY tag_id, tag_name
ORDER BY tag_name]],
  tables = {'tag_listing_index'},
})

define('tag.listing_count', {
  sql = 'SELECT COUNT(*) AS total FROM tag_listing_index WHERE tag_id = ?',
  tables = {'tag_listing_index'},
})

define('tag.listing_rows', {
  sql = [[SELECT entity_type type, entity_id id, user_id, language, title, teaser, body, created, changed, status, promote, route FROM tag_listing_index WHERE tag_id = ? ORDER BY created DESC{{limit}}]],
  tables = {'tag_listing_index'},
})

define('tag.listing_insert', {
  sql = [[INSERT INTO tag_listing_index(
  tag_id, tag_name, entity_type, entity_id, user_id,
  language, title, teaser, body, created, changed,
  status, promote, route, updated_at
) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)]],
  tables = {'tag_listing_index'},
})

define('tag.listing_clear', {
  sql = 'DELETE FROM tag_listing_index',
  tables = {'tag_listing_index'},
})

define('tag.listing_clear_tag', {
  sql = 'DELETE FROM tag_listing_index WHERE tag_id = ?',
  tables = {'tag_listing_index'},
})

--[[ What the listing projection is built from.

  Preferably `content_public`, which is itself a projection; the `legacy` pair
  reads the normalized `content` for a site whose content projection is missing
  or has not been built. Both pairs exist with and without a tag filter, so a
  rebuild of one tag and a rebuild of all of them are two statements rather than
  one string with a clause appended to it.
]]
define('tag.source_rows', {
  sql = [[SELECT t.id tag_id, t.name tag_name, 'content' entity_type, cp.id entity_id,
  cp.user_id, cp.language, cp.title, cp.teaser, cp.body,
  cp.created, cp.changed, cp.status, cp.promote
FROM content_public cp
JOIN field_tag ft ON ft.entity_type = 'content' AND ft.entity_id = cp.id
JOIN tag t ON t.id = ft.tag_id
WHERE cp.status = 1]],
  tables = {'content_public', 'field_tag', 'tag'},
})

define('tag.source_rows_for_tag', {
  sql = [[SELECT t.id tag_id, t.name tag_name, 'content' entity_type, cp.id entity_id,
  cp.user_id, cp.language, cp.title, cp.teaser, cp.body,
  cp.created, cp.changed, cp.status, cp.promote
FROM content_public cp
JOIN field_tag ft ON ft.entity_type = 'content' AND ft.entity_id = cp.id
JOIN tag t ON t.id = ft.tag_id
WHERE cp.status = 1 AND ft.tag_id = ?]],
  tables = {'content_public', 'field_tag', 'tag'},
})

define('tag.legacy_source_rows', {
  sql = [[SELECT t.id tag_id, t.name tag_name, 'content' entity_type, c.id entity_id,
  c.user_id, c.language, c.title, c.teaser, c.body,
  c.created, c.changed, c.status, c.promote
FROM content c
JOIN field_tag ft ON ft.entity_type = 'content' AND ft.entity_id = c.id
JOIN tag t ON t.id = ft.tag_id
WHERE c.status = 1]],
  tables = {'content', 'field_tag', 'tag'},
})

define('tag.legacy_source_rows_for_tag', {
  sql = [[SELECT t.id tag_id, t.name tag_name, 'content' entity_type, c.id entity_id,
  c.user_id, c.language, c.title, c.teaser, c.body,
  c.created, c.changed, c.status, c.promote
FROM content c
JOIN field_tag ft ON ft.entity_type = 'content' AND ft.entity_id = c.id
JOIN tag t ON t.id = ft.tag_id
WHERE c.status = 1 AND ft.tag_id = ?]],
  tables = {'content', 'field_tag', 'tag'},
})

return true
