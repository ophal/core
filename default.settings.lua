settings.slash = string.sub(package.config,1,1)
settings.theme = [[basic]]
settings.language = [[en]]
settings.language_dir = [[ltr]]
settings.site_frontpage = [[lorem_ipsum]]
settings.site_name = [[Ophal]]
settings.cache = false

--[=[ Active/Disabled modules
  List of Ophal modules to load.

  Example:

  settings.modules = {
    mymodule = true,
    othermodule = false, -- disabled module
  }
]=]
settings.modules = {
  lorem_ipsum = true,
}

--[=[ Extend jailed environment
  Ophal code is jailed into a environment with few functions. Use the
  global variable 'env' to add external functions and lua modules.

  Example:

  require [[external.library]]
  env.myfunction = external.library.function
]=]
