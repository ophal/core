--[[ Seeds the database the OpenResty smoke harness measures against.

  One seeder, one set of rows, one schema per dialect -- the SQLite and
  PostgreSQL halves of INSTALL.md, in the order the document installs them.
  Only the normalized tables are created here: the projection tables come from
  `ophal migrate apply`, and the projection *rows* are left for the first
  request to build, because rebuilding from inside a GET is the behavior Phase
  3 introduced and a seeded projection would hide it.

  It seeds through the query layer, which it did not before stage 8.7. Going
  straight at lsqlite3 was defensible while SQLite was the only backend; a
  second dialect would have meant a second hand-rolled binding path beside it,
  each with its own placeholder spelling and its own escaping. The layer
  already owns one audited escaper per driver and one placeholder rendering per
  dialect, and it is what the site under measurement runs on. What that costs
  is a `settings` table this file builds itself -- which is what an installer
  does anyway, and the reason the old comment gave for not using the layer.

  The connection comes from the environment, and it is the same environment the
  profile's generated `settings.lua` reads, so the harness cannot seed one
  database and then measure another:

    OPHAL_SMOKE_DB_DRIVER   sqlite3 (the default), postgresql, mysql
    OPHAL_SMOKE_DB          the SQLite path, or the database name
    OPHAL_SMOKE_DB_HOST     server backends only
    OPHAL_SMOKE_DB_PORT
    OPHAL_SMOKE_DB_USER
    OPHAL_SMOKE_DB_PASS

  Usage: resty tests/smoke/seed_database.lua
]]

package.path = './?.lua;./?/init.lua;' .. package.path

local getenv = os.getenv

local driver = getenv('OPHAL_SMOKE_DB_DRIVER') or 'sqlite3'
local database = getenv('OPHAL_SMOKE_DB')
local host = getenv('OPHAL_SMOKE_DB_HOST') or '127.0.0.1'
local port = tonumber(getenv('OPHAL_SMOKE_DB_PORT') or '')
local username = getenv('OPHAL_SMOKE_DB_USER')
local password = getenv('OPHAL_SMOKE_DB_PASS')

assert(type(database) == 'string' and database ~= '',
  'OPHAL_SMOKE_DB names the database, and is unset')

--[[ Built here rather than read from the profile's settings file.

  The layer resolves `settings.db` once per process through
  `includes/database/config.lua`, so a table is all it wants, and a seeder that
  loaded the site's settings would be loading a file written for a running
  site -- session paths, module lists, a theme -- to get six keys out of it.
]]
settings = {
  db = {
    default = {
      driver = driver,
      database = database,
      host = host,
      port = port,
      username = username,
      password = password,
    },
  },
  performance = {query_stats = false},
}

--[[ The connection a server backend is dropped and created from.

  `postgres` is the database that is always there, and a `DROP DATABASE` cannot
  be issued from inside the database it drops. SQLite needs none of this: the
  harness works in a fresh temporary directory, so its file does not exist yet.
]]
if driver ~= 'sqlite3' then
  settings.db.maintenance = {
    driver = driver,
    -- The database that is always there and always readable: `postgres` on
    -- PostgreSQL, and `information_schema` on MySQL, where the connection has
    -- to name one and the system database may well be closed to this account.
    -- A `CREATE DATABASE` is not scoped to the connection's own database on
    -- either, so which one it is does not matter beyond being reachable.
    database = driver == 'postgresql' and 'postgres' or 'information_schema',
    host = host,
    port = port,
    username = username,
    password = password,
  }
end

local registry = require 'includes.database.registry'
local router = require 'includes.database.router'
-- The same digest layer `modules/user` hashes with. Requiring it here is what
-- lets the seed store a password the real `password_verify()` accepts without
-- this file restating a hashing scheme.
local digest = require 'includes.digest'
require 'includes.database.statements'

--[[ The seeder's own statements, declared the way every other statement is.

  A database name and a sequence's table and column cannot be bind parameters,
  so they are identifiers -- and `registry.trusted` is the honest guard for
  them: they come from this file and from the harness's own environment, never
  from data. That is the claim the name exists to make, in the one place
  `grep -rn trusted` will find it.
]]
registry.define('smoke.drop_database', {
  sql = 'DROP DATABASE IF EXISTS {database}',
  idents = {database = registry.trusted},
  order = {'database'},
  tables = {},
})

registry.define('smoke.create_database', {
  sql = 'CREATE DATABASE {database}',
  idents = {database = registry.trusted},
  order = {'database'},
  tables = {},
})

--[[ Move a sequence past the ids the seed wrote.

  Every seeded row names its id, so the site reads correctly and nothing has
  advanced the sequence -- and PostgreSQL's `core.last_insert_id` is
  `CURRVAL('<table>_<field>_seq')`, so the first article an author creates
  would collide with the first article the seed wrote. SQLite has nothing to do
  here: `AUTOINCREMENT` tracks the highest rowid the table holds, whoever
  wrote it.
]]
registry.define('smoke.sequence_reset', {
  sql = [[SELECT setval('{table:bare}_{field:bare}_seq',
  (SELECT MAX({field}) FROM {table})) AS value]],
  idents = {table = registry.trusted, field = registry.trusted},
  order = {'table', 'field'},
  tables = {},
})

registry.define('smoke.auto_increment_reset', {
  sql = 'ALTER TABLE {table} AUTO_INCREMENT = 1',
  idents = {table = registry.trusted},
  order = {'table'},
  tables = {},
})

local now = os.time()

local sqlite_schema = {
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
  description TEXT,
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

  -- Route redirect storage. `type` is the HTTP status the redirect answers
  -- with; an empty column is served as 302.
  [[CREATE TABLE route_redirect(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  source VARCHAR(255),
  target VARCHAR(255),
  language VARCHAR(12),
  type INTEGER
)]],
  [[CREATE INDEX idx_route_redirect_source_language_id ON route_redirect (source, language, id)]],
  [[CREATE INDEX idx_route_redirect_target_language_id ON route_redirect (target, language, id)]],

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

  --[[ Comments.

    The comment module was in no test profile at all until 2026-09-09, which is
    why `save_service()` could answer 401 for a comment that does not exist and
    nothing noticed. This is INSTALL.md's comment schema after its 2026-09-08
    correction -- `parent_id`, `language` and `sticky` are columns the module
    writes, and the `entity_type` and `title` the document used to name are
    columns nothing touches.
  ]]
  [[CREATE TABLE comment(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  entity_id UNSIGNED BIG INT,
  parent_id UNSIGNED BIG INT,
  user_id UNSIGNED BIG INT,
  language VARCHAR(12),
  body TEXT,
  created UNSIGNED BIG INT,
  changed UNSIGNED BIG INT,
  status BOOLEAN,
  sticky BOOLEAN
)]],
  [[CREATE INDEX idx_comment_entity ON comment (entity_id, created)]],
}

--[[ The PostgreSQL half of the same document.

  Transcribed from INSTALL.md's `####PostgreSQL` blocks in the order the
  document installs them, statement for statement, because this is the first
  thing in the project that executes them. A schema the documentation describes
  and nothing runs is a schema nobody has checked.

  The `id` columns are `integer NOT NULL` with a sequence and a default rather
  than `serial`, which is what the document says and what a `pg_dump` of an
  Ophal site produces. It matters beyond style: `core.last_insert_id` reads
  `CURRVAL('<table>_<field>_seq')`, so the sequence has to carry exactly that
  name.
]]
local postgresql_schema = {
  [[CREATE TABLE content(
  id integer NOT NULL,
  user_id bigint,
  language character varying(12),
  title character varying(255),
  teaser text,
  body text,
  created bigint,
  changed bigint,
  status smallint,
  sticky smallint,
  comment smallint,
  promote smallint
)]],
  [[CREATE SEQUENCE content_id_seq START WITH 1 INCREMENT BY 1 NO MINVALUE NO MAXVALUE CACHE 1]],
  [[ALTER SEQUENCE content_id_seq OWNED BY content.id]],
  [[ALTER TABLE ONLY content ALTER COLUMN id SET DEFAULT nextval('content_id_seq'::regclass)]],
  [[ALTER TABLE ONLY content ADD CONSTRAINT content_pkey PRIMARY KEY (id)]],
  [[CREATE INDEX idx_content_created ON content USING btree (created DESC)]],
  [[CREATE INDEX idx_content_changed ON content USING btree (changed DESC)]],
  [[CREATE INDEX idx_content_frontpage ON content USING btree (promote, status, sticky, created DESC)]],
  [[CREATE INDEX idx_content_title ON content USING btree (title)]],
  [[CREATE INDEX idx_content_user ON content USING btree (user_id)]],
  [[CREATE TABLE comment(
  id integer NOT NULL,
  entity_id bigint,
  parent_id bigint,
  user_id bigint,
  language character varying(12),
  body text,
  created bigint,
  changed bigint,
  status smallint,
  sticky smallint
)]],
  [[CREATE SEQUENCE comment_id_seq START WITH 1 INCREMENT BY 1 NO MINVALUE NO MAXVALUE CACHE 1]],
  [[ALTER SEQUENCE comment_id_seq OWNED BY comment.id]],
  [[ALTER TABLE ONLY comment ALTER COLUMN id SET DEFAULT nextval('comment_id_seq'::regclass)]],
  [[ALTER TABLE ONLY comment ADD CONSTRAINT comment_pkey PRIMARY KEY (id)]],
  [[CREATE INDEX idx_comment_created ON comment USING btree (created DESC)]],
  [[CREATE INDEX idx_comment_entity ON comment USING btree (entity_id)]],
  [[CREATE INDEX idx_comment_user ON comment USING btree (user_id)]],
  [[CREATE TABLE users(
    id integer NOT NULL,
    name character varying(255),
    mail character varying(255),
    pass character varying(255),
    active smallint,
    created bigint
  )]],
  [[CREATE SEQUENCE users_id_seq START WITH 1 INCREMENT BY 1 NO MINVALUE NO MAXVALUE CACHE 1]],
  [[ALTER SEQUENCE users_id_seq OWNED BY users.id]],
  [[ALTER TABLE ONLY users ALTER COLUMN id SET DEFAULT nextval('users_id_seq'::regclass)]],
  [[ALTER TABLE ONLY users ADD CONSTRAINT users_pkey PRIMARY KEY (id)]],
  [[CREATE UNIQUE INDEX unq_idx_user_name ON users USING btree (name)]],
  [[CREATE INDEX idx_user_created ON users USING btree (created)]],
  [[CREATE INDEX idx_user_mail ON users USING btree (mail)]],
  [[CREATE TABLE role (
    id character varying(255) NOT NULL,
    name character varying(255),
    active smallint,
    weight integer
  )]],
  [[ALTER TABLE ONLY role ADD CONSTRAINT role_pkey PRIMARY KEY (id)]],
  [[CREATE UNIQUE INDEX unq_idx_role_name ON role USING btree (name)]],
  [[CREATE INDEX idx_role_weight ON role USING btree (weight)]],
  [[CREATE TABLE user_role (
    user_id bigint NOT NULL,
    role_id character varying(255) NOT NULL
  )]],
  [[ALTER TABLE ONLY user_role ADD CONSTRAINT user_role_pkey PRIMARY KEY (user_id, role_id)]],
  [[CREATE TABLE role_permission (
    role_id character varying(255) NOT NULL,
    permission character varying(255) NOT NULL,
    module character varying(255)
  )]],
  [[ALTER TABLE ONLY role_permission ADD CONSTRAINT role_permission_pkey PRIMARY KEY (role_id, permission)]],
  [[CREATE INDEX idx_role_permission_perm ON role_permission USING btree (permission)]],
  [[CREATE TABLE field_tag(
  entity_type character varying(255) NOT NULL,
  entity_id bigint NOT NULL,
  tag_id bigint NOT NULL
)]],
  [[ALTER TABLE ONLY field_tag ADD CONSTRAINT field_tag_pkey PRIMARY KEY (entity_type, entity_id, tag_id)]],
  [[CREATE TABLE tag(
  id integer NOT NULL,
  user_id bigint,
  name character varying(255),
  description text,
  created bigint,
  changed bigint,
  status smallint
)]],
  [[CREATE SEQUENCE tag_id_seq START WITH 1 INCREMENT BY 1 NO MINVALUE NO MAXVALUE CACHE 1]],
  [[ALTER SEQUENCE tag_id_seq OWNED BY tag.id]],
  [[ALTER TABLE ONLY tag ALTER COLUMN id SET DEFAULT nextval('tag_id_seq'::regclass)]],
  [[ALTER TABLE ONLY tag ADD CONSTRAINT tag_pkey PRIMARY KEY (id)]],
  [[CREATE INDEX idx_tag_name ON tag USING btree (name)]],
  [[CREATE INDEX idx_tag_created ON tag USING btree (created DESC)]],
  [[CREATE INDEX idx_tag_changed ON tag USING btree (changed DESC)]],
  [[CREATE INDEX idx_tag_user ON tag USING btree (user_id)]],
  [[CREATE TABLE route_alias(
  id integer NOT NULL,
  source character varying(255),
  alias character varying(255),
  language character varying(12)
)]],
  [[CREATE SEQUENCE route_alias_id_seq START WITH 1 INCREMENT BY 1 NO MINVALUE NO MAXVALUE CACHE 1]],
  [[ALTER SEQUENCE route_alias_id_seq OWNED BY route_alias.id]],
  [[ALTER TABLE ONLY route_alias ALTER COLUMN id SET DEFAULT nextval('route_alias_id_seq'::regclass)]],
  [[ALTER TABLE ONLY route_alias ADD CONSTRAINT route_alias_pkey PRIMARY KEY (id)]],
  [[CREATE INDEX idx_route_alias_alias_language_id ON route_alias USING btree (alias, language, id)]],
  [[CREATE INDEX idx_route_alias_source_language_id ON route_alias USING btree (source, language, id)]],
  [[CREATE TABLE route_redirect(
  id integer NOT NULL,
  source character varying(255),
  target character varying(255),
  language character varying(12),
  type integer
)]],
  [[CREATE SEQUENCE route_redirect_id_seq START WITH 1 INCREMENT BY 1 NO MINVALUE NO MAXVALUE CACHE 1]],
  [[ALTER SEQUENCE route_redirect_id_seq OWNED BY route_redirect.id]],
  [[ALTER TABLE ONLY route_redirect ALTER COLUMN id SET DEFAULT nextval('route_redirect_id_seq'::regclass)]],
  [[ALTER TABLE ONLY route_redirect ADD CONSTRAINT route_redirect_pkey PRIMARY KEY (id)]],
  [[CREATE INDEX idx_route_redirect_source_language_id ON route_redirect USING btree (source, language, id)]],
  [[CREATE INDEX idx_route_redirect_target_language_id ON route_redirect USING btree (target, language, id)]],
  [[CREATE TABLE file(
  id integer NOT NULL,
  user_id bigint,
  filename character varying(255),
  filepath character varying(255),
  filemime character varying(255),
  filesize bigint,
  status smallint,
  timestamp bigint
)]],
  [[CREATE SEQUENCE file_id_seq START WITH 1 INCREMENT BY 1 NO MINVALUE NO MAXVALUE CACHE 1]],
  [[ALTER SEQUENCE file_id_seq OWNED BY file.id]],
  [[ALTER TABLE ONLY file ALTER COLUMN id SET DEFAULT nextval('file_id_seq'::regclass)]],
  [[ALTER TABLE ONLY file ADD CONSTRAINT file_pkey PRIMARY KEY (id)]],
  [[CREATE INDEX idx_file_timestamp ON file USING btree (timestamp DESC)]],
  [[CREATE INDEX idx_file_user ON file USING btree (user_id)]],
  [[CREATE INDEX idx_file_filename ON file USING btree (filename)]],
}

--[[ The MySQL half, which INSTALL.md did not have until this ran.

  Written from the pair above rather than transcribed, because there was nothing
  to transcribe: `ophal migrate` had no MySQL branch and the document said so.
  INSTALL.md's `####MySQL` blocks are this schema, copied there once it had
  installed a working site -- the one section of that document that was proven
  before it was written rather than after.

  The order is the same and the columns are the same. The types are the MySQL
  spellings of what the other two use, with one deliberate narrowing: an id or a
  foreign key is `INT`, not `BIGINT`. PostgreSQL already declares every `id` as
  `integer`, so this is faithful rather than a compromise -- and it is load
  bearing, because `lua-resty-mysql` converts `INT` to a Lua number and leaves
  `BIGINT` a string. `content.user_id == account.id` is an authorization check,
  and `"2" == 2` is false.

  Indexes are declared inside `CREATE TABLE` rather than after it. MySQL 8 has
  no `CREATE INDEX IF NOT EXISTS` (MariaDB does), and a schema that installs on
  one of them and not the other is worse than one that installs on neither;
  inside the table there is nothing to be idempotent about.

  `AUTO_INCREMENT` is what `db:last_insert_id()` reads back through
  `LAST_INSERT_ID()`, so the seeded rows have to leave it past their own ids --
  see the sequence note above, which is the same problem with a different name
  and the same fix.
]]
local mysql_schema = {
  -- Content module.
  [[CREATE TABLE content(
  id INT AUTO_INCREMENT PRIMARY KEY,
  user_id INT,
  language VARCHAR(12),
  title VARCHAR(255),
  teaser TEXT,
  body TEXT,
  created BIGINT,
  changed BIGINT,
  status SMALLINT,
  sticky SMALLINT,
  comment SMALLINT,
  promote SMALLINT,
  KEY idx_content_created (created DESC),
  KEY idx_content_changed (changed DESC),
  KEY idx_content_frontpage (promote, status, sticky, created DESC),
  KEY idx_content_title (title),
  KEY idx_content_user (user_id)
)]],

  -- User module.
  [[CREATE TABLE users(
  id INT AUTO_INCREMENT PRIMARY KEY,
  name VARCHAR(255),
  mail VARCHAR(255),
  pass VARCHAR(255),
  active SMALLINT,
  created BIGINT,
  UNIQUE KEY unq_idx_user_name (name),
  KEY idx_user_created (created),
  KEY idx_user_mail (mail)
)]],
  [[CREATE TABLE role(
  id VARCHAR(255) NOT NULL PRIMARY KEY,
  name VARCHAR(255),
  active SMALLINT,
  weight INT,
  UNIQUE KEY unq_idx_role_name (name),
  KEY idx_role_weight (weight)
)]],
  [[CREATE TABLE user_role(
  user_id INT NOT NULL,
  role_id VARCHAR(255) NOT NULL,
  PRIMARY KEY (user_id, role_id)
)]],
  [[CREATE TABLE role_permission(
  role_id VARCHAR(255) NOT NULL,
  permission VARCHAR(255) NOT NULL,
  module VARCHAR(255),
  PRIMARY KEY (role_id, permission),
  KEY idx_role_permission_perm (permission)
)]],

  -- Tag module.
  [[CREATE TABLE field_tag(
  entity_type VARCHAR(255) NOT NULL,
  entity_id INT NOT NULL,
  tag_id INT NOT NULL,
  PRIMARY KEY(entity_type, entity_id, tag_id)
)]],
  [[CREATE TABLE tag(
  id INT AUTO_INCREMENT PRIMARY KEY,
  user_id INT,
  name VARCHAR(255),
  description TEXT,
  created BIGINT,
  changed BIGINT,
  status SMALLINT,
  KEY idx_tag_name (name),
  KEY idx_tag_created (created DESC),
  KEY idx_tag_changed (changed DESC),
  KEY idx_tag_user (user_id)
)]],

  -- Route alias storage.
  [[CREATE TABLE route_alias(
  id INT AUTO_INCREMENT PRIMARY KEY,
  source VARCHAR(255),
  alias VARCHAR(255),
  language VARCHAR(12),
  KEY idx_route_alias_alias_language_id (alias, language, id),
  KEY idx_route_alias_source_language_id (source, language, id)
)]],

  [[CREATE TABLE route_redirect(
  id INT AUTO_INCREMENT PRIMARY KEY,
  source VARCHAR(255),
  target VARCHAR(255),
  language VARCHAR(12),
  type INT,
  KEY idx_route_redirect_source_language_id (source, language, id),
  KEY idx_route_redirect_target_language_id (target, language, id)
)]],

  -- File storage.
  [[CREATE TABLE file(
  id INT AUTO_INCREMENT PRIMARY KEY,
  user_id INT,
  filename VARCHAR(255),
  filepath VARCHAR(255),
  filemime VARCHAR(255),
  filesize BIGINT,
  status SMALLINT,
  timestamp BIGINT,
  KEY idx_file_timestamp (timestamp DESC),
  KEY idx_file_user (user_id),
  KEY idx_file_filename (filename)
)]],

  -- Comments.
  [[CREATE TABLE comment(
  id INT AUTO_INCREMENT PRIMARY KEY,
  entity_id INT,
  parent_id INT,
  user_id INT,
  language VARCHAR(12),
  body TEXT,
  created BIGINT,
  changed BIGINT,
  status SMALLINT,
  sticky SMALLINT,
  KEY idx_comment_entity (entity_id, created)
)]],
}

local schema = {
  sqlite3 = sqlite_schema,
  postgresql = postgresql_schema,
  mysql = mysql_schema,
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
    fixtures.author_name, digest.hex('sha256', fixtures.author_pass), now},

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

  -- `tag/service` creates a row of its own, which no other scenario exercises:
  -- the authoring test attaches an existing tag by id. That is how the `tag`
  -- table went without a `description` column everywhere it was declared while
  -- both of the module's INSERT statements named one.
  {[[INSERT INTO role_permission(role_id, permission, module)
VALUES('authenticated', 'create tags', 'tag')]]},

  -- What `comment_access()` asks for. `access comments` is anonymous because
  -- the fetch service is an anonymous JSON read -- it is the request that was
  -- a projection candidate on argument only, and having it in a profile at
  -- all is what turns that argument into a number.
  {[[INSERT INTO role_permission(role_id, permission, module)
VALUES('anonymous', 'access comments', 'comment')]]},
  {[[INSERT INTO role_permission(role_id, permission, module)
VALUES('authenticated', 'access comments', 'comment')]]},
  {[[INSERT INTO role_permission(role_id, permission, module)
VALUES('authenticated', 'post comments', 'comment')]]},
  {[[INSERT INTO role_permission(role_id, permission, module)
VALUES('authenticated', 'edit own comments', 'comment')]]},

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

--[[ Seeded through the connection the site itself will use.

  `db:execute()` is the layer's path for SQL that is not a declaration, and DDL
  is exactly that: it is written once, by hand, from the documentation. What
  the layer supplies is the two things a second dialect would otherwise have
  forced this file to write twice -- `?` rendered as the driver spells it, and
  one audited escaper for a driver that cannot bind.

  Nothing here opens a transaction. SQLite is in autocommit until a statement
  starts one, PostgreSQL wraps each statement on its own, and a `CREATE
  DATABASE` cannot run inside a transaction block at all.
]]
local db = router.get()
local dialect = db:dialect()

assert(schema[dialect], ('no seed schema for the %q dialect; INSTALL.md has no '
  .. '%s section to transcribe one from'):format(dialect, dialect))

if dialect ~= 'sqlite3' then
  local admin = router.get('maintenance')

  admin:with('smoke.drop_database', database):run()
  admin:with('smoke.create_database', database):run()
  admin:release(true)
end

for _, statement in ipairs(schema[dialect]) do
  db:execute(statement)
end

for _, row in ipairs(rows) do
  db:execute(unpack(row))
end

-- Every seeded id is written out, so the counters are behind the rows.
local sequences = {
  {'users', 'id'},
  {'content', 'id'},
  {'tag', 'id'},
  {'route_alias', 'id'},
}

if dialect == 'postgresql' then
  for _, pair in ipairs(sequences) do
    db:with('smoke.sequence_reset', pair[1], pair[2]):run()
  end
elseif dialect == 'mysql' then
  -- MySQL advances `AUTO_INCREMENT` past an explicit id on its own, but only
  -- while the table stays open; `ALTER TABLE ... AUTO_INCREMENT` states it, and
  -- an `AUTO_INCREMENT` lower than the rows present is raised to fit rather
  -- than refused, so this cannot make the counter wrong.
  for _, pair in ipairs(sequences) do
    db:with('smoke.auto_increment_reset', pair[1]):run()
  end
end

db:release(true)

-- The harness reads these back so its assertions and this file cannot drift.
for name, value in pairs(fixtures) do
  print(('SEED_%s=%s'):format(name:upper(), value))
end
