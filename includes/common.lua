local pairs, tcon, rawset, date = pairs, table.concat, rawset, os.date
local base_path = base_path
local str_replace = seawolf.text.str_replace

function page_set_title(header_title, title)
  if header_title then
    if title == nil then title = header_title end
    ophal.title = title
    ophal.header_title = (header_title and header_title .. ' | ' or '') .. settings.site.name
  else
    ophal.header_title = settings.site.name
  end
end

do
  local javascript = {}
  function add_js(data, options)
    if options == nil then options = {} end
    if data ~= nil then
      javascript[data] = options
    end
  end

  function get_js()
    local output = {}
    for k, v in pairs(javascript) do
      rawset(output, #output + 1, ([[<script type="text/javascript" src="%s%s"></script>
]]):format(base_path, k))
    end
    return tcon(output)
  end
end

do
  local css = {}
  function add_css(data, options)
    if options == nil then options = {} end
    if data ~= nil then
      css[data] = options
    end
  end

  function get_css()
    local output = {}
    for k, v in pairs(css) do
      rawset(output, #output + 1, ([[<link type="text/css" rel="stylesheet" media="all" href="%s%s" />
]]):format(base_path, k))
    end
    return tcon(output)
  end
end

function exit_ophal()
  -- call hook exit
  if module_invoke_all then
    module_invoke_all 'exit'
  end

  -- destroy session (phase end)
  if settings.sessionapi and session_write_close then
    session_write_close()
  end

  -- flush output buffer
  if settings.output_buffering then
    output_flush()
  end
end

--[[
  Send the user to a different Ophal page.

  This issues an on-site HTTP redirect. The function makes sure the redirected
  URL is formatted correctly.

  This function ends the request; use it rather than a print theme('page')
  statement in your menu callback.

  @param path
    A Drupal path or a full URL.
  @param query
    The query string component, if any.
  @param fragment
    The destination fragment identifier (named anchor).
  @param http_response_code
    Valid values for an actual "goto" as per RFC 2616 section 10.3 are:
    - 301 Moved Permanently (the recommended value for most redirects)
    - 302 Found (default in Drupal and PHP, sometimes used for spamming search
          engines)
    - 303 See Other
    - 304 Not Modified
    - 305 Use Proxy
    - 307 Temporary Redirect (an alternative to "503 Site Down for Maintenance")
    Note: Other values are defined by RFC 2616, but are rarely used and poorly
          supported.

  @see get_destination()
]]
function goto(path, http_response_code)
  path = path or ''
  http_response_code = http_response_code or 302

  local dest_url

  dest_url = url(path, {absolute = true})
  -- Remove newlines from the URL to avoid header injection attacks.
  dest_url = str_replace({'\n', '\r'}, '', dest_url)

  header('status', http_response_code)
  header('location', dest_url)
  header('connection', 'close')

  exit_ophal()
end

--[[
  Format given unix timestamp by system date format.
]]
function format_date(uts)
  return date(settings.date_format, uts)
end
