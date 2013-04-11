settings.slash = string.sub(package.config,1,1)
settings.theme = 'basic'
settings.language = 'en'
settings.language_dir = 'ltr'
settings.site = {
  frontpage = 'lorem_ipsum',
  name = 'Ophal',
  hash = nil,
  logo_title = 'The Ophal Project',
  logo_path = 'images/ophalproject.png',
}
settings.cache = false
settings.debugapi = true
settings.maintenance_mode = false
settings.output_buffering = false
settings.sessionapi = true
settings.formapi = false
settings.date_format = '!%Y-%m-%d %H:%M UTC'

--[[ Active/Disabled modules
  List of Ophal modules to load on bootstrap.

  Example:

  settings.modules = {
    mymodule = true,
    othermodule = false, -- disabled module
  }
]]
settings.modules = {
  lorem_ipsum = true,
}

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

--[[ Extend jailed environment
  Ophal code is jailed into an environment with few functions. Use the
  global variable 'env' to add external functions and lua modules.

  Example:

  require 'external.library'
  env.myfunction = external.library.function
]]

--[[ Mobile support settings
  The mobile_detect library is a helper for mobile web development.
  Set settings.mobile to nil to turn off mobile support.
  Always make sure to set settings.domain_name if settings.redirect is
  set to true.

  Example:
  settings.mobile = {
    theme = 'mobile',
    domain_name = 'mobile.mydomain.com',
    redirect = true,
  }
]]

--[[
  Boost provides static cache by saving all the output to files.

  Example:

  settings.modules.boost = true
  settings.boost = {
    path = 'files/boost/',
    lifetime = 3600, -- seconds
    signature = '<!-- Page cached by Boost @ %s, expires @ %s -->',
    date_format = '!%Y-%m-%d %T UTC',
  }
]]
