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
  ]]
  db = {
    default = {
      driver = 'SQLite3',
      database = '/path/to/database.ext',
    }
  },
}

return m
