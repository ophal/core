#!/usr/bin/env luajit

require [[includes.bootstrap]]

settings.output_buffering = false

ophal.bootstrap(5, function ()
  -- Settings
  settings.site = {
    name = 'Ophal',
    logo_title = 'The Ophal Project',
    logo_path = 'images/ophalproject.png',
  }
  settings.slash = string.sub(package.config,1,1)
  settings.theme = 'install'
  settings.language = 'en'
  settings.language_dir = 'ltr'

  -- Bootstrap
  require 'includes.path'
  require 'includes.common'
  require 'includes.theme'

  page_set_title 'Welcome!'

  -- Render page
  print_t{'html',
    header_title = ophal.header_title,
    title = ophal.title,
    content = 'Welcome to the Ophal installation process.',
    javascript = get_js(),
    css = get_css(),
  }
end)
