-- Seeds the SQLite database the OpenResty smoke harness measures against.
--
-- The schema here is the SQLite half of INSTALL.md, kept in the same order the
-- document installs it. Only the normalized tables are created: the projection
-- tables come from `ophal migrate apply`, and the projection *rows* are left
-- for the first request to build, because rebuilding from inside a GET is the
-- behavior Phase 3 introduced and a seeded projection would hide it.
--
-- Usage: lua5.1 tests/smoke/seed_database.lua <database-path>

local DBI = require 'DBI'
-- The digest `modules/user` resolves for `sha256` under this vendor runtime,
-- where neither `lsha2` nor `sha2` is installed and `seawolf.other` does not
-- build. Requiring it here is what lets the seed store a password the real
-- `password_verify()` accepts without this file restating a hashing scheme.
local sha256 = require 'includes.sha256'

local path = ...

assert(type(path) == 'string' and path ~= '', 'usage: seed_database.lua <database-path>')

local now = os.time()

local schema = {
  -- Content module.
  [[CREATE TABLE content(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  user_id UNSIGNED BIG INT,
  language VARCHAR(12),
  title VARCHAR(255),
  teaser TEXT,
  body TEXT,
  created UNSIGNED BIG INT,
  changed UNSIGNED BIG INT,
  status BOOLEAN,
  sticky BOOLEAN,
  comment BOOLEAN,
  promote BOOLEAN
)]],
  [[CREATE INDEX idx_content_created ON content (created DESC)]],
  [[CREATE INDEX idx_content_changed ON content (changed DESC)]],
  [[CREATE INDEX idx_content_frontpage ON content (promote, status, sticky, created DESC)]],
  [[CREATE INDEX idx_content_title ON content (title)]],
  [[CREATE INDEX idx_content_user ON content (user_id)]],

  -- User module.
  [[CREATE TABLE users(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  name VARCHAR(255),
  mail VARCHAR(255),
  pass VARCHAR(255),
  active BOOLEAN,
  created UNSIGNED BIG INT
)]],
  [[CREATE UNIQUE INDEX unq_idx_user_name ON users (name)]],
  [[CREATE INDEX idx_user_created ON users (created)]],
  [[CREATE INDEX idx_user_mail ON users (mail)]],
  [[CREATE TABLE role(
  id VARCHAR(255) PRIMARY KEY,
  name VARCHAR(255),
  active BOOLEAN,
  weight INT
)]],
  [[CREATE UNIQUE INDEX unq_idx_role_name ON role (name)]],
  [[CREATE INDEX idx_role_weight ON role (weight)]],
  [[CREATE TABLE user_role(
  user_id UNSIGNED BIG INT,
  role_id VARCHAR(255),
  PRIMARY KEY (user_id, role_id)
)]],
  [[CREATE TABLE role_permission(
  role_id VARCHAR(255),
  permission VARCHAR(255),
  module VARCHAR(255),
  PRIMARY KEY (role_id, permission)
)]],
  [[CREATE INDEX idx_role_permission_perm ON role_permission (permission)]],

  -- Tag module.
  [[CREATE TABLE field_tag(
  entity_type VARCHAR(255),
  entity_id UNSIGNED BIG INT,
  tag_id UNSIGNED BIG INT,
  PRIMARY KEY(entity_type, entity_id, tag_id)
)]],
  [[CREATE TABLE tag(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  user_id UNSIGNED BIG INT,
  name VARCHAR(255),
  created UNSIGNED BIG INT,
  changed UNSIGNED BIG INT,
  status BOOLEAN
)]],
  [[CREATE INDEX idx_tag_name ON tag (name)]],
  [[CREATE INDEX idx_tag_created ON tag (created DESC)]],
  [[CREATE INDEX idx_tag_changed ON tag (changed DESC)]],
  [[CREATE INDEX idx_tag_user ON tag (user_id)]],

  -- Route alias storage.
  [[CREATE TABLE route_alias(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  source VARCHAR(255),
  alias VARCHAR(255),
  language VARCHAR(12)
)]],
  [[CREATE INDEX idx_route_alias_alias_language_id ON route_alias (alias, language, id)]],
  [[CREATE INDEX idx_route_alias_source_language_id ON route_alias (source, language, id)]],

  -- File storage. These are the columns `modules/file` actually reads and
  -- writes, which are not the ones INSTALL.md documents for this table. The
  -- code is what the smoke suite has to agree with, because the code is what
  -- runs.
  [[CREATE TABLE file(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  user_id UNSIGNED BIG INT,
  filename VARCHAR(255),
  filepath VARCHAR(255),
  filemime VARCHAR(255),
  filesize UNSIGNED BIG INT,
  status BOOLEAN,
  timestamp UNSIGNED BIG INT
)]],
  [[CREATE INDEX idx_file_timestamp ON file (timestamp DESC)]],
  [[CREATE INDEX idx_file_user ON file (user_id)]],
}

-- Every seeded string a smoke assertion greps for is spelled once, here, so a
-- renamed fixture cannot leave an assertion passing against the wrong page.
local fixtures = {
  content_title = 'Smoke Seeded Article',
  content_body = 'SMOKE_CONTENT_BODY_MARKER',
  second_title = 'Smoke Second Article',
  unpromoted_title = 'Smoke Unpromoted Article',
  -- The oldest promoted article, and the only one that lands on page two of
  -- the front page. See the filler rows below.
  pager_tail_title = 'Smoke Pager Tail Article',
  tag_name = 'SmokeTag',
  alias = 'smoke-article',
  author_name = 'smokeauthor',
  author_pass = 'smoke-author-pass',
}

local rows = {
  -- Owns the seeded content and never signs in, so its password hash stays
  -- inert.
  {[[INSERT INTO users(id, name, mail, pass, active, created)
VALUES(1, 'root', 'root@example.com', 'x', 1, ?)]], now},

  -- The account the authoring measurements sign in as. It is deliberately not
  -- user 1: `user.access()` returns true for id 1 before it consults a single
  -- permission, so authoring measured as root would measure the superuser
  -- shortcut and leave the seeded `role_permission` rows carrying no weight.
  --
  -- The stored hash is the legacy format, a bare digest of the password, since
  -- that is the only shape this file can produce without restating
  -- `password_hash()`'s salt and iteration scheme -- a copy that would then be
  -- free to drift from the module. `password_verify()` accepts it and reports
  -- that it needs rehashing, so the first sign-in rewrites it in the current
  -- format. That is the documented upgrade path, and running it here is the
  -- only exercise `password_rehash_account()` gets against a real database.
  {[[INSERT INTO users(id, name, mail, pass, active, created)
VALUES(2, ?, 'author@example.com', ?, 1, ?)]],
    fixtures.author_name, sha256.hash256(fixtures.author_pass), now},

  {[[INSERT INTO role(id, name, active, weight) VALUES('anonymous', 'Anonymous user', 1, 1)]]},
  {[[INSERT INTO role(id, name, active, weight) VALUES('authenticated', 'Authenticated user', 1, 2)]]},

  -- The permissions an anonymous render actually checks: `access content`
  -- guards the content page, `access tags` guards the tag listing route.
  {[[INSERT INTO role_permission(role_id, permission, module)
VALUES('anonymous', 'access content', 'user')]]},
  {[[INSERT INTO role_permission(role_id, permission, module)
VALUES('anonymous', 'access tags', 'tag')]]},
  {[[INSERT INTO role_permission(role_id, permission, module)
VALUES('authenticated', 'access content', 'user')]]},
  {[[INSERT INTO role_permission(role_id, permission, module)
VALUES('authenticated', 'access tags', 'tag')]]},

  -- What `content.entity_access()` asks for on the authoring path. Without
  -- them the save service answers 401 and the authoring budget would be
  -- measuring a rejection rather than a write.
  {[[INSERT INTO role_permission(role_id, permission, module)
VALUES('authenticated', 'create content', 'content')]]},
  {[[INSERT INTO role_permission(role_id, permission, module)
VALUES('authenticated', 'edit own content', 'content')]]},

  {[[INSERT INTO user_role(user_id, role_id) VALUES(1, 'authenticated')]]},
  {[[INSERT INTO user_role(user_id, role_id) VALUES(2, 'authenticated')]]},

  -- Promoted and published: this is the row the front page must show.
  {[[INSERT INTO content(id, user_id, language, title, teaser, body, created, changed, status, sticky, comment, promote)
VALUES(1, 1, 'en', ?, ?, ?, ?, ?, 1, 0, 0, 1)]],
    fixtures.content_title, fixtures.content_body, fixtures.content_body, now, now},

  {[[INSERT INTO content(id, user_id, language, title, teaser, body, created, changed, status, sticky, comment, promote)
VALUES(2, 1, 'en', ?, 'Second teaser', 'Second body', ?, ?, 1, 0, 0, 1)]],
    fixtures.second_title, now - 60, now - 60},

  -- Unpublished and unpromoted, so the anonymous listing has something it is
  -- required to leave out. A projection that ignored `status` would show it.
  {[[INSERT INTO content(id, user_id, language, title, teaser, body, created, changed, status, sticky, comment, promote)
VALUES(3, 1, 'en', ?, 'Hidden teaser', 'Hidden body', ?, ?, 0, 0, 0, 0)]],
    fixtures.unpromoted_title, now - 120, now - 120},

  -- Eight more promoted articles, so that with the two above and the tail
  -- below the front page has eleven and therefore two pages at the default
  -- `items_per_page` of 10. Without a second page there is no `?page=2` to
  -- assert on, and the pager argument reaches `pager_current_page()` through
  -- request state that no scenario was watching.
  --
  -- They are inserted between the seeded articles and the tail in `created`
  -- order, so page one still holds `content_title` and page two holds only the
  -- tail.
  {[[INSERT INTO content(id, user_id, language, title, teaser, body, created, changed, status, sticky, comment, promote)
VALUES(10, 1, 'en', 'Smoke Filler Article 1', 'Filler teaser', 'Filler body', ?, ?, 1, 0, 0, 1)]], now - 200, now - 200},
  {[[INSERT INTO content(id, user_id, language, title, teaser, body, created, changed, status, sticky, comment, promote)
VALUES(11, 1, 'en', 'Smoke Filler Article 2', 'Filler teaser', 'Filler body', ?, ?, 1, 0, 0, 1)]], now - 300, now - 300},
  {[[INSERT INTO content(id, user_id, language, title, teaser, body, created, changed, status, sticky, comment, promote)
VALUES(12, 1, 'en', 'Smoke Filler Article 3', 'Filler teaser', 'Filler body', ?, ?, 1, 0, 0, 1)]], now - 400, now - 400},
  {[[INSERT INTO content(id, user_id, language, title, teaser, body, created, changed, status, sticky, comment, promote)
VALUES(13, 1, 'en', 'Smoke Filler Article 4', 'Filler teaser', 'Filler body', ?, ?, 1, 0, 0, 1)]], now - 500, now - 500},
  {[[INSERT INTO content(id, user_id, language, title, teaser, body, created, changed, status, sticky, comment, promote)
VALUES(14, 1, 'en', 'Smoke Filler Article 5', 'Filler teaser', 'Filler body', ?, ?, 1, 0, 0, 1)]], now - 600, now - 600},
  {[[INSERT INTO content(id, user_id, language, title, teaser, body, created, changed, status, sticky, comment, promote)
VALUES(15, 1, 'en', 'Smoke Filler Article 6', 'Filler teaser', 'Filler body', ?, ?, 1, 0, 0, 1)]], now - 700, now - 700},
  {[[INSERT INTO content(id, user_id, language, title, teaser, body, created, changed, status, sticky, comment, promote)
VALUES(16, 1, 'en', 'Smoke Filler Article 7', 'Filler teaser', 'Filler body', ?, ?, 1, 0, 0, 1)]], now - 800, now - 800},
  {[[INSERT INTO content(id, user_id, language, title, teaser, body, created, changed, status, sticky, comment, promote)
VALUES(17, 1, 'en', 'Smoke Filler Article 8', 'Filler teaser', 'Filler body', ?, ?, 1, 0, 0, 1)]], now - 900, now - 900},

  -- The eleventh and oldest, alone on page two.
  {[[INSERT INTO content(id, user_id, language, title, teaser, body, created, changed, status, sticky, comment, promote)
VALUES(18, 1, 'en', ?, 'Tail teaser', 'Tail body', ?, ?, 1, 0, 0, 1)]],
    fixtures.pager_tail_title, now - 10000, now - 10000},

  {[[INSERT INTO tag(id, user_id, name, created, changed, status) VALUES(1, 1, ?, ?, ?, 1)]],
    fixtures.tag_name, now, now},
  {[[INSERT INTO field_tag(entity_type, entity_id, tag_id) VALUES('content', 1, 1)]]},

  {[[INSERT INTO route_alias(id, source, alias, language) VALUES(1, 'content/1', ?, 'en')]],
    fixtures.alias},
}

local dbh, err = DBI.Connect('SQLite3', path)
assert(dbh, err)
dbh:autocommit(true)

local function run(statement, ...)
  local sth, prepare_err = dbh:prepare(statement)
  assert(sth, prepare_err)

  local ok, execute_err = sth:execute(...)
  assert(ok, execute_err)
  sth:close()
end

for _, statement in ipairs(schema) do
  run(statement)
end

for _, row in ipairs(rows) do
  run(unpack(row))
end

dbh:close()

-- The harness reads these back so its assertions and this file cannot drift.
for name, value in pairs(fixtures) do
  print(('SEED_%s=%s'):format(name:upper(), value))
end
