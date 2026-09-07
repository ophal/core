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
}

-- Every seeded string a smoke assertion greps for is spelled once, here, so a
-- renamed fixture cannot leave an assertion passing against the wrong page.
local fixtures = {
  content_title = 'Smoke Seeded Article',
  content_body = 'SMOKE_CONTENT_BODY_MARKER',
  second_title = 'Smoke Second Article',
  unpromoted_title = 'Smoke Unpromoted Article',
  tag_name = 'SmokeTag',
  alias = 'smoke-article',
}

local rows = {
  -- One user to own the content. The password hash is inert: nothing in the
  -- smoke suite logs in, and the anonymous budget is what is being measured.
  {[[INSERT INTO users(id, name, mail, pass, active, created)
VALUES(1, 'root', 'root@example.com', 'x', 1, ?)]], now},

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

  {[[INSERT INTO user_role(user_id, role_id) VALUES(1, 'authenticated')]]},

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
