Ophal installation instructions
===============================

This document is just a brief. For a comprehensive installation guide please
refer to the online Ophal manual: http://ophal.org/manual.


## I. Runtime and server configuration

Ophal now runs on OpenResty only. CGI support has been removed.

These instructions assume that you installed Ophal at `/var/www/ophal`.

NOTE: Ophal remains compatible with SQLite and PostgreSQL only. For the
performance architecture track, PostgreSQL is the required production SQL
backend. SQLite is kept for development, CLI work, tests, and low-scale
compatibility deployments.

### OpenResty

Use `nginx.ophal.conf` as the starting point for your server configuration and
make sure to set:

- `server_name`
- `root`
- log paths

The document root must contain the Ophal tree, including:

- `index.lua`
- `cron.lua`
- `settings.lua`
- `vault.lua`

The provided `nginx.ophal.conf` is also responsible for blocking direct access
to internal Lua source and secret files such as `settings.lua` and `vault.lua`.

Declare the projection version zone in the enclosing `http { }` block:

```nginx
lua_shared_dict ophal_projection_versions 1m;
```

This one is easy to skip and expensive to skip. It cannot live in
`nginx.ophal.conf` itself, because `lua_shared_dict` is an http-level directive
and that file is a `server { }` block, so it is the one piece of required
configuration the shipped file cannot carry for you.

It is how a worker tells the others that a projection has changed. Without it
Ophal does not fail: it falls back to a per-worker table and keeps serving.
What it stops doing is telling the other workers, so on a site with more than
one worker a write becomes visible to whichever worker performed it and stays
invisible to the rest until they happen to restart. The symptom is a page that
alternates between the old and new version depending on which worker answers,
which is a hard thing to attribute to a missing line in an unrelated file.

The name has to match; the module resolves `ophal_projection_versions` and
falls back silently on a typo. If you rename the zone, set
`settings.performance.projection_shared_dict` to the same name.

Operational note: `0.2.x` runs inside persistent OpenResty workers, but it is
not yet a fully nonblocking stack. Database access still uses synchronous
`LuaDBI`, and some filesystem operations still occur on request paths for
templates, asset metadata, sessions, and uploads. Treat the current runtime as
correct and persistent, but operationally bounded by those blocking paths.

Template and static-asset metadata are now cached with a short runtime TTL to
reduce repeated `stat()` calls. The default TTL is `1` second and can be tuned
through `settings.runtime_cache`.

Operationally, `0.2.x` should be treated as suitable for low-to-moderate
traffic. It is not positioned as a fully nonblocking high-concurrency stack
until an OpenResty-native database path exists.

OpenResty plus PostgreSQL assumptions for this line:

- PostgreSQL is the required production backend for the performance
  architecture work
- the current runtime still opens synchronous LuaDBI connections during
  bootstrap, so keep database latency low and prefer a local or private-network
  PostgreSQL deployment or pooler
- SQLite remains a supported compatibility path, but not the target backend
  for the performance architecture


## II. Dependencies

### OpenResty and Lua modules

Ophal targets the OpenResty runtime and its bundled LuaJIT environment. Install
the required Lua modules for that runtime.

Required for any site:

- LPeg
- LuaFilesystem
- luuid
- dkjson
- LuaSocket
- lsqlite3, for SQLite
- pgmoon, for PostgreSQL
- luaossl, only if your PostgreSQL server authenticates with a password
- Seawolf

MySQL needs nothing installed: `lua-resty-mysql` ships with OpenResty.

No cryptography library is needed. See the note in `README.md`: SHA-256 is the
default password algorithm and a pure-Lua implementation ships with Ophal.

### Debian

```sh
$ sudo apt-get install uuid-dev libsqlite3-dev libpq-dev
$ sudo luarocks install lpeg
$ sudo luarocks install luafilesystem
$ sudo luarocks install luuid
$ sudo luarocks install dkjson
$ sudo luarocks install luasocket
$ cd /tmp
$ git clone --depth=1 https://github.com/ophal/seawolf.git
$ sudo mv seawolf /usr/local/share/lua/5.1/
```

Then the database bindings. SQLite goes through `lsqlite3`, and
`lsqlite3complete` is the same binding with SQLite statically linked, so it
needs no system library of its own:

```sh
$ sudo luarocks install lsqlite3complete
```

PostgreSQL goes through `pgmoon`, which serves both the OpenResty worker and the
`ophal` command line -- it uses cosockets under OpenResty and LuaSocket under
plain `lua5.1`, and picks between them itself:

```sh
$ sudo luarocks install pgmoon
```

`pgmoon` needs an OpenSSL binding to authenticate with a password. This is not
optional on a default PostgreSQL 14 or later, where `scram-sha-256` is the
default method, and it applies to the worker as much as to the command line:

```sh
$ sudo luarocks install luaossl
```

MySQL needs no rock at all: `lua-resty-mysql` ships with OpenResty.

It has **no blocking mode**, though, which is the one way a MySQL site differs
from the other two in operation. The `ophal` script is `#!/usr/bin/env lua5.1`,
which has no cosockets, so on MySQL the command line runs under `resty` --
which ships with OpenResty as well -- instead:

```sh
$ resty -c 512 ./ophal migrate apply
```

Everything else is the same, and the migrations carry a MySQL branch. There is
one behavioural difference worth knowing before you write a module: that driver
converts every numeric column type to a Lua number *except* `BIGINT`, which it
leaves as a string, because a 64-bit integer does not fit a Lua number exactly.
The shipped schema uses `INT` for every id and foreign key for that reason, so
comparisons of ids behave the same on all three backends; a `BIGINT` column --
a unix second, a file size -- needs `tonumber` before it is compared in Lua.
Arithmetic coerces on its own; comparison does not.

### Upgrading from a release before 2026-09-08

**LuaDBI is gone.** It read integer columns with 32-bit precision on SQLite and
PostgreSQL -- so a timestamp breaks in January 2038 and a file over 2 GB reads
wrong today -- and returned an empty string for a SQL NULL on MySQL,
indistinguishable from a column that really holds one. None of that is
repairable above the binding.

Your `driver` names keep working and now resolve to the replacements:
`sqlite3` is lsqlite3, `postgresql` is pgmoon, `mysql` is `lua-resty-mysql`.
Install what your backend needs from the list above; a site that upgrades
without doing so stops at boot with a message naming the rock, rather than
failing somewhere inside its first query. A settings file that spells a LuaDBI
binding explicitly -- `driver = 'luadbi-postgresql'` -- is told what replaced it.

`examples/Dockerfile` performs this same install against
`openresty/openresty:bullseye-fat` and is the quickest way to check the list is
still current.


## III. Installation

The supported install path is now the CLI.

From the project root:

```sh
$ ./ophal install check
$ ./ophal install init /var/www/ophal
```

This will verify runtime dependencies and scaffold:

- `settings.lua`
- `vault.lua`
- the files directory
- `.htaccess` inside the files directory

`install init` scaffolds a PostgreSQL-backed configuration by default.
`--db-driver` takes `PostgreSQL`, `MySQL` or `SQLite3`; any other name is
refused, and a name that used to work is told what replaced it. Use `SQLite3`
only when you explicitly want the compatibility or development path, and note
that a MySQL site has to run the `ophal` command line under `resty`, as the
next section describes.

Review the generated configuration, make any desired changes, and set
appropriate filesystem permissions before starting OpenResty.


### Apply the schema migrations

```sh
$ ./ophal migrate status
$ ./ophal migrate apply
```

On MySQL, run both under `resty` -- `resty -c 512 ./ophal migrate apply` -- for
the reason given under Dependencies: that driver has no blocking mode and the
`ophal` script runs on plain Lua.

This creates two kinds of table. `route_index`, `content_public`,
`tag_listing_index` and `projection_version` are the read path: they hold no
data of their own, since every row in them is derived from the normalized
tables below and can be rebuilt from them at any time. `ophal_jobs` is the
queue that schedules those rebuilds, described in the next section.

A site that skips this step still serves correct pages. Every read that prefers
a projection falls back to the normalized tables when the projection is missing,
so the effect of not migrating is cost, not breakage: the fast path is simply
never taken.


### Deferred work and the cron schedule

Schedule `/cron`. It is not a background nicety on this line: since `0.2.x` a
projection that is stale or has never been built is no longer rebuilt inside the
request that noticed it. The request enqueues the rebuild, serves the page from
the normalized tables, and returns; `/cron` is what drains that queue.

A site that never runs cron still serves correct pages, and it is not stuck on
the fallback forever -- once a queued rebuild has sat there longer than Ophal
was willing to wait, the next request that notices does the rebuild itself. But
that is the behaviour cron exists to avoid: the rebuild reads a whole table, and
whoever is waiting on that page pays for it. Scheduling cron is what keeps that
cost off your visitors.

Every five minutes is a reasonable starting point. The interval is what bounds
how long a projection stays stale after a write, so tune it against that rather
than against load:

```
*/5 * * * * curl -fsS -o /dev/null http://127.0.0.1/cron
```

Add `?token=...` to that URL if you configure a token below.

`./ophal jobs status` reports how much work is waiting, which is the number to
watch if pages seem to be serving from the fallback for longer than expected.

The endpoint drains work that is unbounded in the size of the tables it
rebuilds, so an anonymous caller able to ask for it on demand is an amplifier.
Two layers guard it, and they cover different failures:

- `nginx.ophal.conf` ships `allow 127.0.0.1; deny all;` in the `/cron`
  location. This holds even if Lua never runs, and it is what protects a
  deployment that has not configured a token.
- `settings.cron.token` is compared, in constant time, against a `token=` query
  argument or an `X-Ophal-Cron-Token` request header.

Configure the token if cron runs from anywhere other than localhost -- through
a proxy, from another host, or from a scheduler that reaches nginx as a remote
client. In `vault.lua`:

```Lua
  cron = {
    token = 'a long random string',
  },
```

And in `settings.lua`:

```Lua
  settings.cron = {
    token = (vault.cron or {}).token,
  }
```

When no token is configured, Ophal logs a `cron_token_missing` warning and
allows the request. That is deliberate: refusing would silently stop the
scheduled work of every deployment that upgrades without editing its vault, and
the nginx `allow`/`deny` above already covers the default. The warning is what
makes the gap visible.


### Uploads

Two nginx settings decide how much work an upload costs Ophal, and neither is
required for correctness.

`client_body_buffer_size` is the threshold above which nginx buffers a request
body to disk instead of holding it in memory. Ophal takes advantage of that: a
chunk nginx has already written to disk is renamed into place rather than read
back into Lua and written again, so a body over this threshold costs no copy at
all. Bodies under it stay in memory and are written normally.

For that rename to work, nginx's `client_body_temp_path` must be on the same
filesystem as `settings.site.files_path`. A rename cannot cross devices, and
when it fails Ophal falls back to copying the bytes — correct, and slower, with
nothing in the response to say so. If uploads are slower than expected, check
those two paths are on one filesystem first.

`client_max_body_size` bounds a single request and therefore a single chunk. It
defaults to 1m, and `settings.file.bytes_per_chunk` also defaults to 1MB, so
the two sit exactly on top of each other; raise the nginx limit if you raise the
chunk size.


### Performance settings

Every key below is optional and has a working default, so a site that sets none
of them is configured correctly. They are documented because the defaults are
otherwise only readable in the source, and because two of them are the ones you
reach for when something is wrong rather than slow.

```Lua
  settings.performance = {
    -- Caching
    projection_payload_cache_size = 512,
    user_cache_size = 512,
    projection_version_miss_ttl = 5,
    projection_shared_dict = 'ophal_projection_versions',

    -- Deferred work
    projection_rebuild_pending_ttl = 900,
    jobs = {
      claim_limit = 20,
      max_attempts = 5,
      retry_backoff = 60,
    },

    -- Measurement. Off in production; the test suite turns them on.
    query_stats = false,
    projection_cache_stats = false,
    fs_stats = false,
  }
```

**Caching.** `projection_payload_cache_size` bounds the per-worker cache of
rendered projection payloads, per projection rather than globally, because
projection keys come from code and so the number of buckets is fixed.
`user_cache_size` does the same for the role, permission and user-object caches,
keyed by user id — that key space grows with accounts, so this is the one to
lower on a site with many users and little memory. Setting either to `0`
disables that cache rather than making it unbounded.

`projection_version_miss_ttl` is how long a worker remembers that a projection
version row was absent. It exists because a nil and a missing key are
indistinguishable in a Lua table, so without it an untouched key costs one
query on every request forever. Leave it non-zero unless you are testing.

`projection_shared_dict` only matters if you renamed the `lua_shared_dict` zone
declared in Section I. The two names must agree; they fail apart silently.

**Deferred work.** `projection_rebuild_pending_ttl` is how long a queued
projection rebuild is trusted before a request stops waiting for it. If the
queue has visibly stopped moving — a job older than this is still sitting there
— the request rebuilds inline instead, which is what stops a site whose cron
broke from deferring forever. Raising it lengthens the window in which pages
come from the normalized fallback; setting it to `0` means "defer indefinitely"
and disables that recovery, because a shared-dictionary entry written with no
expiry never lapses.

The `jobs` keys bound the drain: how many jobs one `/cron` request claims, how
many times a failing job is retried before it is left alone, and how long it
waits between attempts.

**Measurement.** The three counters are off by default and cost one boolean
test each when off. `query_stats` and `fs_stats` are what the smoke suite's
query and filesystem budgets are expressed in; `projection_cache_stats` reports
hits, misses, stale lookups, evictions and occupancy per projection. Turn that
one on if you suspect the payload cache is too small: absent keys next to
evictions mean the bucket is undersized, while stale keys mean writes are
outpacing reads, and only the first is fixed by raising the size.


### (Optional) Configure the Content module
Run the following SQL queries in strict order:

####SQLite
```SQL
CREATE TABLE content(
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
);
CREATE INDEX idx_content_created ON content (created DESC);
CREATE INDEX idx_content_changed ON content (changed DESC);
CREATE INDEX idx_content_frontpage ON content (promote, status, sticky, created DESC);
CREATE INDEX idx_content_title ON content (title);
CREATE INDEX idx_content_user ON content (user_id);
```

####PostgreSQL
```SQL
CREATE TABLE content(
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
);
CREATE SEQUENCE content_id_seq START WITH 1 INCREMENT BY 1 NO MINVALUE NO MAXVALUE CACHE 1;
ALTER SEQUENCE content_id_seq OWNED BY content.id;
ALTER TABLE ONLY content ALTER COLUMN id SET DEFAULT nextval('content_id_seq'::regclass);
ALTER TABLE ONLY content ADD CONSTRAINT content_pkey PRIMARY KEY (id);
CREATE INDEX idx_content_created ON content USING btree (created DESC);
CREATE INDEX idx_content_changed ON content USING btree (changed DESC);
CREATE INDEX idx_content_frontpage ON content USING btree (promote, status, sticky, created DESC);
CREATE INDEX idx_content_title ON content USING btree (title);
CREATE INDEX idx_content_user ON content USING btree (user_id);
```

####MySQL
```SQL
CREATE TABLE content(
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
);
```

Now add the following to settings.lua:
```Lua
  settings.modules.content = true
```


### (Optional) Configure the Comment module

Run the following SQL queries in strict order:

####SQLite
```SQL
CREATE TABLE comment(
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
);
CREATE INDEX idx_comment_created ON comment (created DESC);
CREATE INDEX idx_comment_entity ON comment (entity_id);
CREATE INDEX idx_comment_user ON comment (user_id);
```

####PostgreSQL
```SQL
CREATE TABLE comment(
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
);
CREATE SEQUENCE comment_id_seq START WITH 1 INCREMENT BY 1 NO MINVALUE NO MAXVALUE CACHE 1;
ALTER SEQUENCE comment_id_seq OWNED BY comment.id;
ALTER TABLE ONLY comment ALTER COLUMN id SET DEFAULT nextval('comment_id_seq'::regclass);
ALTER TABLE ONLY comment ADD CONSTRAINT comment_pkey PRIMARY KEY (id);
CREATE INDEX idx_comment_created ON comment USING btree (created DESC);
CREATE INDEX idx_comment_entity ON comment USING btree (entity_id);
CREATE INDEX idx_comment_user ON comment USING btree (user_id);
```

####MySQL
```SQL
CREATE TABLE comment(
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
);
```

As with the `file` table, these are the columns the module names in its own
`INSERT` and `UPDATE`. An earlier revision documented `entity_type` and `title`,
which nothing reads or writes, and omitted `parent_id`, `language` and
`sticky`, which every insert names — so posting a comment on a site installed
from it failed on the first missing column. Comments attach to content by
`entity_id` alone, which is why the entity index no longer leads with a type.

Now add the following to settings.lua:
```Lua
  settings.modules.comment = true
```


### (Optional) Configure the User module
WARNING! Since the user module allows to start an authenticated session, meaning
that certain users will have access to priviledged data, the use of an SSL
certificated and HTTPS is strongly recommended. Please make sure that your
production server running an Ophal site (with user module enable) is
correctly configured for secure connections.

Run the following SQL queries in strict order:

1. Create schema:

  ####SQLite
  ```SQL
  CREATE TABLE users(
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name VARCHAR(255),
    mail VARCHAR(255),
    pass VARCHAR(255),
    active BOOLEAN,
    created UNSIGNED BIG INT
  );
  CREATE UNIQUE INDEX unq_idx_user_name ON users (name);
  CREATE INDEX idx_user_created ON users (created);
  CREATE INDEX idx_user_mail ON users (mail);

  CREATE TABLE role(
    id VARCHAR(255) PRIMARY KEY,
    name VARCHAR(255),
    active BOOLEAN,
    weight INT
  );
  CREATE UNIQUE INDEX unq_idx_role_name ON role (name);
  CREATE INDEX idx_role_weight ON role (weight);

  CREATE TABLE user_role(
    user_id UNSIGNED BIG INT,
    role_id VARCHAR(255),
    PRIMARY KEY (user_id, role_id)
  );

  CREATE TABLE role_permission(
    role_id VARCHAR(255),
    permission VARCHAR(255),
    module VARCHAR(255),
    PRIMARY KEY (role_id, permission)
  );
  CREATE INDEX idx_role_permission_perm ON role_permission (permission);
  ```

  ####PostgreSQL
  ```SQL
  CREATE TABLE users(
    id integer NOT NULL,
    name character varying(255),
    mail character varying(255),
    pass character varying(255),
    active smallint,
    created bigint
  );
  CREATE SEQUENCE users_id_seq START WITH 1 INCREMENT BY 1 NO MINVALUE NO MAXVALUE CACHE 1;
  ALTER SEQUENCE users_id_seq OWNED BY users.id;
  ALTER TABLE ONLY users ALTER COLUMN id SET DEFAULT nextval('users_id_seq'::regclass);
  ALTER TABLE ONLY users ADD CONSTRAINT users_pkey PRIMARY KEY (id);
  CREATE UNIQUE INDEX unq_idx_user_name ON users USING btree (name);
  CREATE INDEX idx_user_created ON users USING btree (created);
  CREATE INDEX idx_user_mail ON users USING btree (mail);

  CREATE TABLE role (
    id character varying(255) NOT NULL,
    name character varying(255),
    active smallint,
    weight integer
  );
  ALTER TABLE ONLY role ADD CONSTRAINT role_pkey PRIMARY KEY (id);
  CREATE UNIQUE INDEX unq_idx_role_name ON role USING btree (name);
  CREATE INDEX idx_role_weight ON role USING btree (weight);

  CREATE TABLE user_role (
    user_id bigint NOT NULL,
    role_id character varying(255) NOT NULL
  );
  ALTER TABLE ONLY user_role ADD CONSTRAINT user_role_pkey PRIMARY KEY (user_id, role_id);

  CREATE TABLE role_permission (
    role_id character varying(255) NOT NULL,
    permission character varying(255) NOT NULL,
    module character varying(255)
  );
  ALTER TABLE ONLY role_permission ADD CONSTRAINT role_permission_pkey PRIMARY KEY (role_id, permission);
  CREATE INDEX idx_role_permission_perm ON role_permission USING btree (permission);
  ```

  ####MySQL
  ```SQL
  CREATE TABLE users(
    id INT AUTO_INCREMENT PRIMARY KEY,
    name VARCHAR(255),
    mail VARCHAR(255),
    pass VARCHAR(255),
    active SMALLINT,
    created BIGINT,
    UNIQUE KEY unq_idx_user_name (name),
    KEY idx_user_created (created),
    KEY idx_user_mail (mail)
  );

  CREATE TABLE role(
    id VARCHAR(255) NOT NULL PRIMARY KEY,
    name VARCHAR(255),
    active SMALLINT,
    weight INT,
    UNIQUE KEY unq_idx_role_name (name),
    KEY idx_role_weight (weight)
  );

  CREATE TABLE user_role(
    user_id INT NOT NULL,
    role_id VARCHAR(255) NOT NULL,
    PRIMARY KEY (user_id, role_id)
  );

  CREATE TABLE role_permission(
    role_id VARCHAR(255) NOT NULL,
    permission VARCHAR(255) NOT NULL,
    module VARCHAR(255),
    PRIMARY KEY (role_id, permission),
    KEY idx_role_permission_perm (permission)
  );
  ```

2. Generate a bootstrap password hash for superuser with the included CLI:

  ```sh
  $ ./ophal sha256 mypassword
  89e01536ac207279409d4de1e5253e01f4a1769e696db0d6062ca9b8f56767c8
  ```

  Alternatively, you can run the following lua code:

  ```sh
  > print(require 'lsha2'.hash256 'mypassword')
  89e01536ac207279409d4de1e5253e01f4a1769e696db0d6062ca9b8f56767c8
  ```

  NOTICE: this generates a legacy-compatible SHA-256 password hash. Ophal keeps
  login compatibility for this format and upgrades it to the current salted
  versioned format after the first successful login.

3. Create user 1:

  ####SQLite
  ```SQL
  INSERT INTO users VALUES(1, 'root', 'test@example.com', 'your password hash', 1, strftime('%s', 'now'));
  ```

  ####PostgreSQL
  ```SQL
  INSERT INTO users VALUES(1, 'root', 'test@example.com', 'your password hash', 1, extract(epoch from now() at time zone 'utc'));
  ```

  ####MySQL
  ```SQL
  INSERT INTO users VALUES(1, 'root', 'test@example.com', 'your password hash', 1, UNIX_TIMESTAMP());
  ```

4. Enable Form API:

  ```Lua
  settings.formapi = true
  ```

5. Enable this module:

  ```Lua
  settings.modules.user = true
  ```

6. Configure default roles

  ```SQL
  INSERT INTO role VALUES('anonymous', 'Anonymous user', 1, 1);
  INSERT INTO role VALUES('authenticated', 'Authenticated user', 1, 2);
  INSERT INTO role VALUES('administrator', 'Administrator', 1, 3);
  ```

7. Configure default permissions

  ```SQL
  INSERT INTO role_permission VALUES('anonymous', 'access content', 'user');
  INSERT INTO role_permission VALUES('authenticated', 'access content', 'user');
  INSERT INTO role_permission VALUES('authenticated', 'create content', 'user');
  INSERT INTO role_permission VALUES('authenticated', 'edit own content', 'user');
  INSERT INTO role_permission VALUES('administrator', 'administer users', 'user');
  ```


### (Optional) Configure the Tag module

Run the following SQL queries in strict order:

####SQLite
```SQL
CREATE TABLE field_tag(
  entity_type VARCHAR(255),
  entity_id UNSIGNED BIG INT,
  tag_id UNSIGNED BIG INT,
  PRIMARY KEY(entity_type, entity_id, tag_id)
);

CREATE TABLE tag(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  user_id UNSIGNED BIG INT,
  name VARCHAR(255),
  description TEXT,
  created UNSIGNED BIG INT,
  changed UNSIGNED BIG INT,
  status BOOLEAN
);
CREATE INDEX idx_tag_name ON tag (name);
CREATE INDEX idx_tag_created ON tag (created DESC);
CREATE INDEX idx_tag_changed ON tag (changed DESC);
CREATE INDEX idx_tag_user ON tag (user_id);
```

####PostgreSQL
```SQL
CREATE TABLE field_tag(
  entity_type character varying(255) NOT NULL,
  entity_id bigint NOT NULL,
  tag_id bigint NOT NULL
);
ALTER TABLE ONLY field_tag ADD CONSTRAINT field_tag_pkey PRIMARY KEY (entity_type, entity_id, tag_id);

CREATE TABLE tag(
  id integer NOT NULL,
  user_id bigint,
  name character varying(255),
  description text,
  created bigint,
  changed bigint,
  status smallint
);
CREATE SEQUENCE tag_id_seq START WITH 1 INCREMENT BY 1 NO MINVALUE NO MAXVALUE CACHE 1;
ALTER SEQUENCE tag_id_seq OWNED BY tag.id;
ALTER TABLE ONLY tag ALTER COLUMN id SET DEFAULT nextval('tag_id_seq'::regclass);
ALTER TABLE ONLY tag ADD CONSTRAINT tag_pkey PRIMARY KEY (id);
CREATE INDEX idx_tag_name ON tag USING btree (name);
CREATE INDEX idx_tag_created ON tag USING btree (created DESC);
CREATE INDEX idx_tag_changed ON tag USING btree (changed DESC);
CREATE INDEX idx_tag_user ON tag USING btree (user_id);
```

####MySQL
```SQL
CREATE TABLE field_tag(
  entity_type VARCHAR(255) NOT NULL,
  entity_id INT NOT NULL,
  tag_id INT NOT NULL,
  PRIMARY KEY(entity_type, entity_id, tag_id)
);

CREATE TABLE tag(
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
);
```

Now add the following to settings.lua:
```Lua
  settings.modules.tag = true
```


### (Optional) Configure route aliases storage

Run the following SQL queries in strict order:

####SQLite
```SQL
CREATE TABLE route_alias(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  source VARCHAR(255),
  alias VARCHAR(255),
  language VARCHAR(12)
);
CREATE INDEX idx_route_alias_alias_language_id ON route_alias (alias, language, id);
CREATE INDEX idx_route_alias_source_language_id ON route_alias (source, language, id);
```

####PostgreSQL
```SQL
CREATE TABLE route_alias(
  id integer NOT NULL,
  source character varying(255),
  alias character varying(255),
  language character varying(12)
);
CREATE SEQUENCE route_alias_id_seq START WITH 1 INCREMENT BY 1 NO MINVALUE NO MAXVALUE CACHE 1;
ALTER SEQUENCE route_alias_id_seq OWNED BY route_alias.id;
ALTER TABLE ONLY route_alias ALTER COLUMN id SET DEFAULT nextval('route_alias_id_seq'::regclass);
ALTER TABLE ONLY route_alias ADD CONSTRAINT route_alias_pkey PRIMARY KEY (id);
CREATE INDEX idx_route_alias_alias_language_id ON route_alias USING btree (alias, language, id);
CREATE INDEX idx_route_alias_source_language_id ON route_alias USING btree (source, language, id);
```

####MySQL
```SQL
CREATE TABLE route_alias(
  id INT AUTO_INCREMENT PRIMARY KEY,
  source VARCHAR(255),
  alias VARCHAR(255),
  language VARCHAR(12),
  KEY idx_route_alias_alias_language_id (alias, language, id),
  KEY idx_route_alias_source_language_id (source, language, id)
);
```

Now add the following to settings.lua:
```Lua
  settings.route_aliases_storage = true
```


### (Optional) Configure the File module

Run the following SQL queries in strict order:

####SQLite
```SQL
CREATE TABLE file(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  user_id UNSIGNED BIG INT,
  filename VARCHAR(255),
  filepath VARCHAR(255),
  filemime VARCHAR(255),
  filesize UNSIGNED BIG INT,
  status BOOLEAN,
  timestamp UNSIGNED BIG INT
);
CREATE INDEX idx_file_timestamp ON file (timestamp DESC);
CREATE INDEX idx_file_user ON file (user_id);
CREATE INDEX idx_file_filename ON file (filename);
```

####PostgreSQL
```SQL
CREATE TABLE file(
  id integer NOT NULL,
  user_id bigint,
  filename character varying(255),
  filepath character varying(255),
  filemime character varying(255),
  filesize bigint,
  status smallint,
  timestamp bigint
);
CREATE SEQUENCE file_id_seq START WITH 1 INCREMENT BY 1 NO MINVALUE NO MAXVALUE CACHE 1;
ALTER SEQUENCE file_id_seq OWNED BY file.id;
ALTER TABLE ONLY file ALTER COLUMN id SET DEFAULT nextval('file_id_seq'::regclass);
ALTER TABLE ONLY file ADD CONSTRAINT file_pkey PRIMARY KEY (id);
CREATE INDEX idx_file_timestamp ON file USING btree (timestamp DESC);
CREATE INDEX idx_file_user ON file USING btree (user_id);
CREATE INDEX idx_file_filename ON file USING btree (filename);
```

####MySQL
```SQL
CREATE TABLE file(
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
);
```

These are the columns the module reads and writes: `create()` and `update()`
name them directly, and `db_field()` maps a name to itself rather than
translating one, so a differently named column is an absent column and not a
rename. An earlier revision of this section documented `name`, `type`, `size`,
`path`, `created` and `changed`, which no code has ever used -- a site
installed from it could not store a file at all.

`filename` carries its own index because the module looks a file up by it
before accepting an upload, which is how it refuses a name that is already
taken. `filemime` is left null by the upload itself: the type inspection runs
on the deferred queue as `file_post_process`, so the column fills in on the
next `/cron` drain rather than during the request. See "Deferred work and the
cron schedule" above.

Now add the following to settings.lua:
```Lua
  settings.modules.file = true
```


## IV. Troubleshooting

Whether you successfully installed Ophal or not, please file an issue with your
feedback and any problems you find. The runtime and CLI installer are still the
main moving parts for current deployments.
