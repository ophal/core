Installation instructions
=========================

NOTE: Following SQL commands are compatible with SQLite3, you'll need to adapt them for another database engine.

1. Create schema:

    CREATE TABLE user(id INTEGER PRIMARY KEY AUTOINCREMENT, name VARCHAR(255), mail VARCHAR(255), pass VARCHAR(255), active BOOLEAN, created UNSIGNED BIG INT);
    CREATE UNIQUE INDEX unq_idx_user_name ON user (name);
    CREATE INDEX unq_idx_user_created ON user (created);
    CREATE INDEX unq_idx_user_mail ON user (mail);

    CREATE TABLE role(id INTEGER PRIMARY KEY AUTOINCREMENT, name VARCHAR(255), active BOOLEAN, weight INT);
    CREATE UNIQUE INDEX unq_idx_role_name ON role (name);
    CREATE INDEX idx_role_weight ON role (weight);
    INSERT INTO role VALUES(1, 'anonymous', 1, 0);
    INSERT INTO role VALUES(2, 'authenticated', 1, 1);

    CREATE TABLE user_role(user_id UNSIGNED BIG INT, role_id UNSIGNED BIG INT, PRIMARY KEY (user_id, role_id));

    CREATE TABLE role_permission(role_id UNSIGNED BIG INT, permission varchar(255), module varchar(255), PRIMARY KEY (role_id, permission));
    CREATE INDEX idx_permission ON role_permission (permission);

2. Generate a password for superuser with following script:

    crypto = require 'crypto'
    d = crypto.digest.new 'sha256'
    d:update 'mypassword'
    print(d:final())

NOTICE: this script outputs a password hash, change 'mypassword' by 'yourpass'

3. Create user 1:

    INSERT INTO "user" VALUES(1,'root','test@example.com',[password],1,CURRENT_TIMESTAMP);

4. Add math libraries to global env in settings.lua:

    env.maths = require 'seawolf.maths'
    env.math = math

5. Enable Form API:

    settings.formapi = true

6. Enable this module:

    settings.modules.user = true

7. Configure default roles

    --[=[
      User module options
    ]=]
    settings.user = {
      role = {
        anonymous = {
          'access content',
        },
        authenticated = {
          'access content',
        },
      }
    }
