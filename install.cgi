#!/usr/bin/env lua

require 'includes.bootstrap'

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

  -- Detect phase
  local phase = tonumber(_GET.phase) or 1

  -- Load Core API
  require 'includes.path'
  require 'includes.common'
  require 'includes.theme'

  -- Pager
  theme.install_pager = function (variables)
    if variables == nil then variables = {} end

    local options = variables.options
    local previous = ''

    if phase > 1 then
      previous = ('<p><a href="%s%sinstall.cgi?phase=%s"><< Previous</a> '):format(base_root, base_path, phase - 1)
    end

    return table.concat{
      ('<div %s id="install_pager">'):format(render_attributes(options)),
      previous,
      ('<a href="%s%sinstall.cgi?phase=%s">Next >></a></p>'):format(base_root, base_path, phase + 1),
      '</div>'
    }
  end

  -- phases
  local content = ''
  local phases = {
    -- Welcome page
    function ()
      -- Look for settings.lua
      if seawolf.fs.is_file [[settings.lua]] then
        -- Redirect to next phase
        header('location', ('%s%sinstall.cgi?phase=3'):format(base_root, base_path))
        header('connection', 'close')
        io.write ''
        os.exit()
      end

      page_set_title 'Install: Welcome!'

      content = ([[<h3>Welcome to the Ophal installation process.</h3>
<p>Before you proceed, please consider the following</p>
<p><ol>
<li>For enhanced security, do *not* run this installer in production.</li>
<li>Javascript enabled is needed in order to complete the installation.</li>
<li>No dabatase is created by this installer, you need to create one in advance.</li>
</ol>
</p>
]] .. theme.install_pager()):format(base_root, base_path, 2)
    end,

    -- Verify pre-requisites
    function ()
      local libraries, status, err, output, continue
      local tinsert, tconcat = table.insert, table.concat

      -- Look for settings.lua
      if seawolf.fs.is_file 'settings.lua' then
        -- Redirect to next phase
        header('location', ('%s%sinstall.cgi?phase=3'):format(base_root, base_path))
        header('connection', 'close')
        io.write ''
        os.exit()
      end

      page_set_title 'Install: Pre-requisites'
      -- Check 'files' directory permissions

      -- Libraries
      libraries = {
        cgic = {
          name = 'Lua-CGIC',
          required = true,
        },
        ['socket.url'] = {
          name = 'LuaSocket',
          required = true,
        },
        lfs = {
          name = 'LuaFilesystem',
          required = true,
        },
        uuid = {
          name = 'luuid',
          required = true,
        },
        DBI = {
          name = 'LuaDBI',
          required = true,
        },
        lpeg = {
          name = 'LPEG',
          required = false,
        },
      }
      output = {
        '<table>',
        '<thead><th>Library</th><th>Machine name</th><th>Status</th><th>Error</th></thead>'
      }

      -- Find required libraries, both optional and required
      continue = true      
      for machine_name, library in pairs(libraries) do
        tinsert(output, '<tr>')
        tinsert(output, ('<td>%s</td>'):format(library.name))
        tinsert(output, ('<td>"%s"</td>'):format(machine_name))
        -- Status
        status, err = pcall(require, machine_name)
        if status then
          tinsert(output, '<td>OK</td>')
        else
          continue = false
          tinsert(output, ('<td>Missing</td><td><pre>"%s"</pre></td>'):format(err))
        end
        tinsert(output, '</tr>')
      end
      tinsert(output, '</table>')
        -- Say: All requirements are OK
      if continue then
        tinsert(output, theme.install_pager())
      else
        tinsert(output, '<p>Please install any missing library. Read the <a href="http://ophal.org/manual/--version--/install#libraries">documentation</a> for details.</p>')
      end
      content = tconcat(output)
    end,

    -- Generate configuration file
    function ()
      local tinsert, tconcat = table.insert, table.concat

      require [[includes.form]]

      add_js 'misc/jquery.js'
      add_js 'misc/uuid.js'
      local js = [[<script type="text/javascript">
$(document).ready(function() {
  $('#generate').click(function() {
    $('#settings').html($('#settings_template').html()
      .replace('!site_name', $('#sitename').val())
      .replace('!db_filepath', $('#filepath').val())
      .replace('!site_hash', uuid())
    );
    $('#check_settings').show();
    $('#install_pager').show();
  });
});
</script>]],

      page_set_title 'Configuration file: settings.lua'

      local elements = {
        '<h3>1. Configure your site</h3>',
        '<table>',
        '<tr><td>',
        theme.label{title = 'Site name', attributes = {['for'] = 'sitename'}},
        '</td><td>',
        theme.textfield{value = 'Ophal', attributes = {id = 'sitename'}},
        '</td></tr>',
        '<tr><td>',
        theme.label{title = 'Database file path', attributes = {['for'] = 'filepath'}},
        '</td><td>',
        theme.textfield{attributes = {id = 'filepath'}},
        '</td></tr>',
        '</table>',
        theme.button{value = 'Generate', attributes = {id = 'generate'}},
        '<div id="settings"></div>',
        [[<div id="settings_template" style="display:none">
<h3>2. Create file settings.lua</h3>
<p>Copy the following text into the file <i>settings.lua</i> and put it right in the exact same folder of file <i>index.cgi</i>:</p>
<textarea cols="100" rows="15">
settings.slash = string.sub(package.config,1,1)
settings.theme = 'basic'
settings.language = 'en'
settings.language_dir = 'ltr'
settings.site = {
  frontpage = 'lorem_ipsum',
  name = '!site_name',
  hash = '!site_hash',
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

--[=[ Active/Disabled modules
  List of Ophal modules to load on bootstrap.

  Example:

  settings.modules = {
    mymodule = true,
    othermodule = false, -- disabled module
  }
]=]
settings.modules = {
  lorem_ipsum = true,
}

--[=[ Database connection settings
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
]=]
settings.db = {
  default = {
    driver = 'SQLite3',
    database = '!db_filepath',
  }
}

--[=[ Extend jailed environment
  Ophal code is jailed into an environment with few functions. Use the
  global variable 'env' to add external functions and lua modules.

  Example:

  require 'external.library'
  env.myfunction = external.library.function
]=]

--[=[ Mobile support settings
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
]=]

--[=[
  Boost provides static cache by saving all the output to files.

  Example:

  settings.modules.boost = true
  settings.boost = {
    path = 'files/boost/',
    lifetime = 3600, -- seconds
    signature = '<!-- Page cached by Boost @ %s, expires @ %s -->',
    date_format = '!%Y-%m-%d %T UTC',
  }
]=]
</textarea></div>]],
      }

      content = tconcat{
        js, theme.form{action = 'install.cgi', elements = tconcat(elements)},
        theme.install_pager{style = 'display: none;'}
      }
    end,

    -- Do install
    function ()
      page_set_title 'Installing...'
      content = 'Pre-requisites'
    end
  }

  -- Run phase
  phases[phase]()
  
  -- Render page
  print_t{'html',
    header_title = ophal.header_title,
    title = ophal.title,
    content = content,
    javascript = get_js(),
    css = get_css(),
  }
end)
