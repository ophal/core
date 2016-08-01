--[[
  This file is for storage of sensitive information ONLY.
]]

local m = {
  -- Following example tries to keep the structure from settings.lua

  --[[ Site settings ]]
  site = {
    hash = nil,
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
