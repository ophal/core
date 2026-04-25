Ophal installation instructions
===============================

This document is just a brief. For a comprehensive installation guide please
refer to the online Ophal manual: http://ophal.org/manual.


## I. Runtime and server configuration

Ophal now runs on OpenResty only. CGI support has been removed.

These instructions assume that you installed Ophal at `/var/www/ophal`.

NOTE: Ophal is compatible with SQLite and PostgreSQL only.

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


## II. Dependencies

### OpenResty and Lua modules

Ophal targets the OpenResty runtime and its bundled LuaJIT environment. Install
the required Lua modules for that runtime.

### Debian

```sh
$ sudo luarocks install lpeg
$ sudo apt-get install uuid-dev
$ sudo luarocks install luuid
$ sudo luarocks install luafilesystem
$ sudo luarocks install luasocket
$ cd /tmp
$ git clone --depth=1 git://github.com/ophal/seawolf.git
$ sudo mv seawolf /usr/local/share/lua/5.1/
```


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

Review the generated configuration, make any desired changes, and set
appropriate filesystem permissions before starting OpenResty.


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
  user_id UNSIGNED BIG INT,
  entity_type VARCHAR(255),
  entity_id UNSIGNED BIG INT,
  title VARCHAR(255),
  body TEXT,
  created UNSIGNED BIG INT,
  changed UNSIGNED BIG INT,
  status BOOLEAN
);
CREATE INDEX idx_comment_created ON comment (created DESC);
CREATE INDEX idx_comment_entity ON comment (entity_type, entity_id);
CREATE INDEX idx_comment_user ON comment (user_id);
```

####PostgreSQL
```SQL
CREATE TABLE comment(
  id integer NOT NULL,
  user_id bigint,
  entity_type character varying(255),
  entity_id bigint,
  title character varying(255),
  body text,
  created bigint,
  changed bigint,
  status smallint
);
CREATE SEQUENCE comment_id_seq START WITH 1 INCREMENT BY 1 NO MINVALUE NO MAXVALUE CACHE 1;
ALTER SEQUENCE comment_id_seq OWNED BY comment.id;
ALTER TABLE ONLY comment ALTER COLUMN id SET DEFAULT nextval('comment_id_seq'::regclass);
ALTER TABLE ONLY comment ADD CONSTRAINT comment_pkey PRIMARY KEY (id);
CREATE INDEX idx_comment_created ON comment USING btree (created DESC);
CREATE INDEX idx_comment_entity ON comment USING btree (entity_type, entity_id);
CREATE INDEX idx_comment_user ON comment USING btree (user_id);
```

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
  name VARCHAR(255),
  type VARCHAR(255),
  size UNSIGNED BIG INT,
  path VARCHAR(255),
  created UNSIGNED BIG INT,
  changed UNSIGNED BIG INT,
  status BOOLEAN
);
CREATE INDEX idx_file_created ON file (created DESC);
CREATE INDEX idx_file_changed ON file (changed DESC);
CREATE INDEX idx_file_user ON file (user_id);
```

####PostgreSQL
```SQL
CREATE TABLE file(
  id integer NOT NULL,
  user_id bigint,
  name character varying(255),
  type character varying(255),
  size bigint,
  path character varying(255),
  created bigint,
  changed bigint,
  status smallint
);
CREATE SEQUENCE file_id_seq START WITH 1 INCREMENT BY 1 NO MINVALUE NO MAXVALUE CACHE 1;
ALTER SEQUENCE file_id_seq OWNED BY file.id;
ALTER TABLE ONLY file ALTER COLUMN id SET DEFAULT nextval('file_id_seq'::regclass);
ALTER TABLE ONLY file ADD CONSTRAINT file_pkey PRIMARY KEY (id);
CREATE INDEX idx_file_created ON file USING btree (created DESC);
CREATE INDEX idx_file_changed ON file USING btree (changed DESC);
CREATE INDEX idx_file_user ON file USING btree (user_id);
```

Now add the following to settings.lua:
```Lua
  settings.modules.file = true
```


## IV. Troubleshooting

Whether you successfully installed Ophal or not, please file an issue with your
feedback and any problems you find. The runtime and CLI installer are still the
main moving parts for current deployments.
