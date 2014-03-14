#!/usr/bin/env lua5.1

require 'includes.bootstrap'

settings.output_buffering = false

ophal.bootstrap(5, function ()
  -- Settings
  local default_settings = {
    site = {
      name = 'Ophal',
      logo_title = 'The Ophal Project',
      logo_path = 'images/ophalproject.png',
    },
    slash = string.sub(package.config,1,1),
    language = 'en',
    language_dir = 'ltr',
  }

  for k, v in pairs(default_settings) do
    if settings[k] == nil then
      settings[k] = v
    end
  end

  -- Force settings
  settings.theme = 'install'

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
        redirect(('%s%sinstall.cgi?phase=3'):format(base_root, base_path))
      end

      page_set_title 'Phase 1: Welcome!'

      content = ([[<h3>Welcome to the Ophal installation process.</h3>
<p>Before you proceed, please consider the following</p>
<p><ol>
<li>For enhanced security, do *not* run this installer in production.</li>
<li>Javascript enabled is needed in order to complete the installation.</li>
<li>No dabatase is created by this installer, you need to create one in advance.</li>
</ol>
</p>
]] .. theme{'install_pager'}):format(base_root, base_path, 2)
    end,

    -- Verify pre-requisites
    function ()
      local libraries, status, err, output, continue
      local tinsert, tconcat = table.insert, table.concat

      -- Look for settings.lua
      if seawolf.fs.is_file 'settings.lua' then
        -- Redirect to next phase
        redirect(('%s%sinstall.cgi?phase=3'):format(base_root, base_path))
      end

      page_set_title 'Phase 2: Pre-requisites'

      -- Library checker
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
          required = true,
        },
        dkjson = {
          name = "David Kolf's JSON",
          required = true,
        },
        ['seawolf.variable'] = {
          name = 'Seawolf: variable',
          required = true,
        },
        ['seawolf.fs'] = {
          name = 'Seawolf: filesystem',
          required = true,
        },
        ['seawolf.text'] = {
          name = 'Seawolf: text',
          required = true,
        },
        ['seawolf.behaviour'] = {
          name = 'Seawolf: behaviour',
          required = true,
        },
        ['seawolf.contrib'] = {
          name = 'Seawolf: contrib',
          required = true,
        },
      }
      output = {
        '<table>',
        '<thead><th>Library</th><th>Machine name</th><th>Required?</th><th>Status</th><th>Error</th></thead>'
      }

      -- Find required libraries, both optional and required
      continue = true      
      for machine_name, library in pairs(libraries) do
        tinsert(output, '<tr>')
        tinsert(output, ('<td>%s</td>'):format(library.name))
        tinsert(output, ('<td>"%s"</td>'):format(machine_name))
        tinsert(output, ('<td>%s</td>'):format(library.required and 'Required' or 'Optional'))
        -- Status
        status, err = pcall(require, machine_name)
        if status then
          tinsert(output, '<td>Found</td>')
        else
          continue = false
          tinsert(output, ('<td>Missing</td><td><pre>"%s"</pre></td>'):format(err))
        end
        tinsert(output, '</tr>')
      end
      tinsert(output, '</table>')
        -- Say: All requirements are OK
      if continue then
        tinsert(output, theme{'install_pager'})
      else
        tinsert(output, '<p>Please install any missing library. Read the <a href="http://ophal.org/manual/--version--/install#libraries">documentation</a> for details.</p>')
      end
      content = tconcat(output)
    end,

    -- Generate configuration file
    function ()
      local tinsert, tconcat = table.insert, table.concat

      -- Look for settings.lua
      if seawolf.fs.is_file 'settings.lua' then
        -- Redirect to next phase
        redirect(('%s%sinstall.cgi?phase=4'):format(base_root, base_path))
      end

      require 'includes.module'
      require 'includes.form'

      add_js 'libraries/jquery.min.js'
      add_js 'libraries/uuid.js'
      add_js{'install', type = 'inline', content = [[
$(document).ready(function() {
  $('#generate').click(function() {
    $('#settings').html($('#settings_template').html()
      .replace('!site_name', $('#sitename').val())
      .replace('!db_filepath', $('#db_filepath').val())
      .replace('!site_hash', uuid())
      .replace('!files_path', $('#files_path').val())
      .replace('!content_module', $('#content_module').is(':checked'))
    );
    $('#check_settings').show();
    $('#install_pager').show();
  });
});
]]}

      page_set_title 'Phase 3: Configuration file settings.lua'

      content = tconcat{
        '<h3>Step 1. Configure your site</h3>',
        theme{'form', action = 'install.cgi',
          elements = {
            {'textfield', title = 'Site name', value = 'Ophal', attributes = {id = 'sitename'}},
            {'textfield', title = 'Database file path', attributes = {id = 'db_filepath'}},
            {'textfield', title = 'File directory', value = 'files', attributes = {id = 'files_path'}},
            {'checkbox', title = 'Enable the Content module', value = '0', attributes = {id = 'content_module'}},
            {'button', value = 'Generate', attributes = {id = 'generate'}},
          }
        },
        '<div id="settings"></div>',
        [[<div id="settings_template" style="display:none">
<h3>Step 2. Create file settings.lua</h3>
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
  files_path = '!files_path',
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
  content = !content_module,
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
        theme{'install_pager', style = 'display: none;'}
      }
    end,

    -- Do install
    function ()
      local status, err, file_directory, fh
      local tconcat = table.concat
      local output = ''

      -- Load settings
      local status, err = pcall(require, 'settings')

      if not status then
        err = "Missing file or error when trying to load 'settings.lua'"
      else
        err = nil

        -- Check 'files' directory permissions
        if not (settings.site and settings.site.files_path) then
          err = 'settings.site.files_path is not set!'
        else
          files_path = settings.site.files_path

          if seawolf.fs.is_file(files_path) then
            err = ("Created file directory: '%s' is an actual file, not a directory! Please fix and try again."):format(files_path)
          elseif seawolf.fs.is_dir(files_path) then
            if not seawolf.fs.is_writable(files_path) then
              err = ("File directory: '%s' is not writable!"):format(files_path)
            else
              fh = io.open(files_path .. '/.htaccess', 'w')
              fh:write([[SetHandler Ophal_Security_Do_Not_Remove
Options None
Options +FollowSymLinks

]])
              output =
                '<p>Installation complete!</p>' ..
                ('<p>Your new site is available <a href="%s">here</a></p>'):format(base_path)
              fh:close()
            end
          else
            err = ("File directory not found! Please create directory '%s'."):format(files_path)
          end
        end
      end

      page_set_title 'Installing...'
      content = tconcat{
        err and ('<strong>Error</strong>: %s'):format(err) or '',
        output,
      }
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
