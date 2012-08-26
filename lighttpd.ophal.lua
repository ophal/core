-- $Id$

--[[

develCuy's Ultimate Lua Script for running Ophal on Lighty!

Thanks to Garret Albright's script for Drupal.

This script handles URL rewriting, "www." addition/removal, and Boost support
for Ophal installations running on the lighttpd web server daemon. These are
tasks which would be handled by ".htaccess" files when running on the Apache
server.

To use this script, make the necessary modifications in the "Configuration"
section below to suit your needs and save it as ophal.lua somewhere on your
server where the Lighty daemon will be able to read it. Then, add the following
two lines to your lighttpd.conf file (modifying the second line as necessary):

server.modules += ("mod_magnet")
magnet.attract-physical-path-to = ("/path/to/ophal.lua")

Of course, your mileage may vary depending on your existing configuration, but
that's the basics. For more information about mod_magnet and using Lua scripts
with Lighty, see this page in Lighty's documentation wiki:
http://redmine.lighttpd.net/projects/lighttpd/wiki/Docs:ModMagnet

For more information on the Lua scripting language itself, see:
http://lua-users.org/wiki/LearningLua
http://www.lua.org/manual/5.1/

--]]

-- Configuration:
-- "www" addition/removal: If you want this script to ADD the "www." prefix
-- to the host name when requests are made to the server without it, set the
-- "love_www" value to "true" (without quotes). This will cause requests for
-- "http://example.com/" to be redirected to "http://www.example.com/". If
-- you want it to REMOVE the prefix when requests are made to the server WITH
-- it, set the value to "false"; "http://www.example.com/" will be redirected
-- to "http://example.com/". If you don't want to do any redirection either
-- way, set the value to "nil".

love_www = false

-- Subdirectory: If your Ophal installation is in a subdirectory - for
-- example, at http://example.com/ophal/ instead of just
-- http://example.com/ - set the d_path variable below to the path to that
-- directory, with a slash at the beginning AND at the ending of the path. For
-- the example above, you would set d_path to '/ophal/' (with quotes). If
-- your Ophal installation is at your web site's root - for example, just at
-- http://example.com/ - set this variable to a single slash: '/'

d_path = '/'

-- Boost support: Set to "true" (without quotes) to enable rewriting necessary
-- for the Boost module. Set to "false" if you're not using Boost. If you are
-- using Boost, it's strongly recommended that you also enable "www." addition
-- or removal above (set love_www to true or false); otherwise, Boost will
-- create duplicate copies of its cache files.

boost_on = false

-- Boost path header: If set to "true", Boost will add a "X-Boost-Path" HTTP
-- header to Boost cache-worthy requests which either contains the path to
-- the cache file in the case of a cache hit, or the word "miss" in the case
-- of a cache miss. This may be handy when initially setting up or debugging
-- Boost on your server, but you may wish to turn it off (set to "false") for
-- live sites to save a little overhead and possibly for security reasons.

boost_header = false

-- Simple anti-leech protection: If set to "false", anti-leech protection won't
-- kick in. Otherwise, set it to a table (like an array) of file extensions
-- which should be protected. See the commented-out line below for a basic
-- example. Check out this documentation for Lua's simple pattern matching
-- syntax: http://www.lua.org/manual/5.1/manual.html#5.4.1

anti_leech = false

-- anti_leech = { 'jpe?g', 'png', 'gif', 'mov', 'avi', 'wmv', 'mpe?g', 'mp[234]', 'wav', 'wma', 'swf', 'flv' }

-- ---- Stop! You should not need to edit anything else below this line. ---- --

-- Remove "www" from URLs. Note that unlike the .htaccess file that comes with
-- Ophal, you don't have to edit this to add your site's/sites' URL/URLs - we
-- can determine that automatically.
-- Match "www." at the beginning of the URL.
-- Note that Lua's matching system is inspired by standard regular
-- expressions, but is not a drop-in replacement. In this case it's close
-- enough, though. See: http://www.lua.org/manual/5.1/manual.html#5.4.1
-- The match function returns nil when there's no match.

if love_www == false and lighty.env['uri.authority']:match('^www%.') ~= nil then
  -- Rebuild the URL without the "www." and pass it as the "Location" header.
  -- Note that Lua's string counting functions are 1-based (the first character
  -- is at position 1, not position 0 as in most other languages), so the 5
  -- parameter is correct for the sub() function below.
  lighty.header['Location'] = lighty.env['uri.scheme'] .. '://' .. lighty.env['uri.authority']:sub(5) .. lighty.env['request.orig-uri']
  -- Return a 301 Moved Permanently HTTP status code.
  return 301
end

-- Add "www" to URLs. Read the comments in the "Remove 'www'" section above for
-- more info - much of it could be repeated here.

if love_www and lighty.env['uri.authority']:match('^www%.') == nil then
  -- Rebuild URL, adding "www.", and pass it in as the "Location" header.
  lighty.header['Location'] = lighty.env['uri.scheme'] .. '://www.' .. lighty.env['uri.authority'] .. lighty.env['request.orig-uri']
  return 301
end

-- We don't want directories (such as the root document directory when '/' is
-- requested) to be counted as a "file" just because it will respond to
-- lighty.stat() with something other than nil. This bit of ugliness lets us do
-- so without creating another variable to store the results of lighty.stat()
-- and then doing file_exists = stat ~= nil and stat.is_file
local file_exists = lighty.env['physical.path']:sub(-1) ~= '/' and lighty.stat(lighty.env['physical.path']) ~= nil
local path_trimmed = lighty.env['uri.path']:sub(d_path:len() + 1)

-- Anti-leeching
if anti_leech ~= false and file_exists and lighty.request['Referer'] ~= nil then
  for idx, ext in ipairs(anti_leech) do
    if path_trimmed:match('%.' .. ext .. '$') then
      -- This extension is in the blacklist. Is the visitor leeching?
      -- Not using pattern matching here because there doesn't seem to be an
      -- easy way to escape reserved characters in a pattern. Dashes are the
      -- biggest problem in that regard.
      accessing = lighty.env['uri.scheme'] .. '://' .. lighty.env['uri.authority']
      if (lighty.request['Referer']:sub(1,accessing:len()) == accessing) then
        return
      else
        -- Return a 403 Forbidden HTTP status code.
        return 403
      end
    end
  end
end

if boost_on then
  if file_exists then
    -- If the file exists, only try to Boost JS and CSS files (not images or
    -- anything else). This naively assumes all CSS and JS requests will use
    -- their normal extensions, but maybe Boost is using the same assumption…?
    ext = path_trimmed:match('%.%a+')
    if ext ~= '.js' and ext ~= '.css' then
      return
    end
  end
  --[[
Check for the existence of files at physical paths.
@param paths
A table of path info to check, keyed by physical path.
@return
true if a file exists at a path in the table; false otherwise.
--]]
  local check_exists = function(paths)
    for idx, stats in ipairs(paths) do
      if lighty.stat(stats.physical) then
        lighty.env['physical.path'] = stats.physical
        lighty.env['uri.path'] = stats.path
        lighty.env['physical.rel-path'] = stats.path
        lighty.header['Content-Type'] = stats.ctype
        if stats.gzip then
          lighty.header['Content-Encoding'] = 'gzip'
        end
        if boost_header then
          lighty.header['X-Boost-Path'] = stats.path
        end
        return true
      end
    end
    return false
  end

  -- Make sure there's something in the Cookie value to avoid having to check
  -- against nil more than once
  if (lighty.request['Cookie'] == nil) then
    lighty.request['Cookie'] = ''
  end
  
  local gzip_on = (lighty.request['Accept-Encoding'] ~= nil and lighty.request['Accept-Encoding']:find('gzip', 1, true)) or lighty.request['Cookie']:find('boost-gzip', 1, true)

  -- cache/perm files might exist in their non-cache location (in which case,
  -- file_exists == true at this point), but even in that case we want to serve
  -- them from the cache directory anyway (for ghetto Gzip support, for
  -- example).
  local perm = {}

  if path_trimmed == 'boost-gzip-cookie-test.html' then
    -- For whatever reason, OOP-style function calling isn't working on these
    -- tables (perm:insert(item) causes the error "attempt to call method
    -- 'insert' (a nil value)"), so we do it functional-style.
    table.insert(perm, {
      ['physical'] = lighty.env['physical.doc-root'] .. d_path .. 'cache/perm/boost-gzip-cookie-test.html.gz',
      ['ctype'] = 'text/html',
      ['path'] = d_path .. 'cache/perm/boost-gzip-cookie-test.html.gz',
      ['gzip'] = true,
    })
  elseif ext ~= nil then
    local path = d_path .. 'cache/perm/' .. lighty.env['uri.authority'] .. '/' .. path_trimmed .. '_' .. ext
    local physical = lighty.env['physical.doc-root'] .. path
    local types = {
      ['.css'] = 'text/css',
      ['.js'] = 'text/javascript',
    }
    if gzip_on then
      table.insert(perm, {
        ['physical'] = physical .. '.gz',
        ['ctype'] = types[ext],
        ['path'] = path .. '.gz',
        ['gzip'] = true,
      })
    end
    table.insert(perm, {
      ['physical'] = physical,
      ['ctype'] = types[ext],
      ['path'] = path,
      ['gzip'] = false,
    })
  end
  
  boost_hit = #perm ~= 0 and check_exists(perm)
  
  -- If no hits yet, and we might have a hit in cache/normal…
  if not boost_hit then
    if file_exists then
      -- Just serve the file!
      return
    end
    -- Patterns for paths Boost doesn't cache. Lua's patterns lack an "or"
    -- operator like the pipe in regular expressions, so instead of something
    -- like '^(admin|cache|etc)' we have this kludge.
    for idx, path in ipairs({
      '^admin',
      '^cache',
      '^misc',
      '^modules',
      '^sites',
      '^system',
      '^openid',
      '^themes',
      '^node/add',
      '^comment/reply',
      '^edit',
      '^user$',
      '^user/[^%d]',
    }) do
      if path_trimmed:match(path) then
        bad_path = true
        break
      end
    end
    if not bad_path == true and lighty.env['request.method'] == 'GET' and lighty.env['uri.scheme'] ~= 'https' and lighty.request['Cookie']:find('DRUPAL_UID', 1, true) == nil then
      local path = d_path .. 'cache/normal/' .. lighty.env['uri.authority'] .. '/' .. path_trimmed .. '_'
      if lighty.env['uri.query'] ~= nil then
        path = path .. lighty.env['uri.query']
      end
      local physical = lighty.env['physical.doc-root'] .. path
      local types = {
        {
          ['ext'] = '.html',
          ['ctype'] = 'text/html',
        },
        {
          ['ext'] = '.xml',
          ['ctype'] = 'text/xml',
        },
        {
          ['ext'] = '.json',
          ['ctype'] = 'text/javascript',
        },
      }
      local norm = {}
      
      if gzip_on then
        -- Similarly to above, types:ipairs() does not work
        for idx, type in ipairs(types) do
          table.insert(norm, {
            ['physical'] = physical .. type.ext .. '.gz',
            ['ctype'] = type.ctype,
            ['path'] = path .. type.ext .. '.gz',
            ['gzip'] = true,
          })
        end
      end
      for idx, type in ipairs(types) do
        table.insert(norm, {
          ['physical'] = physical .. type.ext,
          ['ctype'] = type.ctype,
          ['path'] = path .. type.ext,
          ['gzip'] = false,
        })
      end
      
      -- Check the norm for hits
      boost_hit = check_exists(norm)
    end
  end
  if boost_header and not boost_hit then
    lighty.header['X-Boost-Path'] = 'miss'
  end
end

if not file_exists and (not boost_on or not boost_hit) then
  -- Rewrite the query part of the URI (or create it if there isn't one) to
  -- append "q=<path>" (while stripping away the path to the Ophal installation
  -- if it's in there).
  if lighty.env['uri.query'] == nil or lighty.env['uri.query']:match('^q=') == nil then
    lighty.env['uri.query'] = (lighty.env['uri.query'] == nil and '' or lighty.env['uri.query'] .. '&') .. 'q=' .. path_trimmed
  end
  lighty.env['uri.path'] = d_path .. 'index.cgi'
  lighty.env['physical.rel-path'] = lighty.env['uri.path']
  lighty.env['physical.path'] = lighty.env['physical.doc-root'] .. lighty.env['physical.rel-path']
end
