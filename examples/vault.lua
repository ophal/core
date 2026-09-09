--[[
  This file is for storage of sensitive information ONLY.
]]

local m = {
  -- Following example tries to keep the structure from settings.lua

  --[[ Site settings ]]
  site = {
    hash = nil,
  },

  --[[ Cron settings
    The shared secret the /cron endpoint requires, passed as `?token=` or as an
    X-Ophal-Cron-Token header. Leave it nil and Ophal warns on every cron run
    and allows it, so an upgrade does not silently stop scheduled work -- the
    `allow`/`deny` in nginx.ophal.conf is what guards that default.
  ]]
  cron = {
    token = nil,
  },

  --[[ Database connection settings
    Ophal automatically connects on bootstrap to a database if a the key
    'db' is set with connection settings.

    `driver` is one of 'PostgreSQL', 'MySQL' or 'SQLite3'. The first two take
    credentials and a host; SQLite is a file and takes neither. On MySQL the
    `ophal` command line runs under `resty`, because that driver has no
    blocking mode -- see INSTALL.md.

    Example:

    settings.db = {
      default = {
        driver = 'PostgreSQL',
        database = 'database',
        username = 'username',
        password = 'password',
        host = 'localhost',
        port = '5432',
      }
    }

    settings.db = {
      default = {
        driver = 'MySQL',
        database = 'database',
        username = 'username',
        password = 'password',
        host = 'localhost',
        port = '3306',
      }
    }
  ]]
  db = {
    default = {
      driver = 'SQLite3',
      database = '/path/to/database.ext',
    }
  },
}

return m
