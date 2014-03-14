local pairs, tcon, rawset, date = pairs, table.concat, rawset, os.date
local base_path, lfs = base_path, lfs
local str_replace, is_file = seawolf.text.str_replace, seawolf.fs.is_file

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
  local order = {}
  add_js = {}
  setmetatable(add_js, {
    __call = function(t, options)
      if options == nil then
        options = {}
      elseif type(options) == 'string' then
        options = {data = options}
      elseif type(options) == 'table' then
        options.data = options[1]
        options[1] = nil
      end

      local data = options.data
      options.data = nil

      local scope = options.scope and options.scope or 'header'

      if javascript[scope] == nil then javascript[scope] = {} end
      if order[scope] == nil then order[scope] = {} end

      if data ~= nil then
        javascript[scope][data] = options
        order[scope][#order[scope] + 1] = data
      end
    end
  })

  function get_js()
    local output = {}

    for scope, v in pairs(order) do
      output[scope] = {}
      for _, j in pairs(v) do
        local options = javascript[scope][j]
        if options ~= nil and options.type == 'inline' then
          output[scope][#output[scope] + 1] = ([[<script type="text/javascript">%s</script>
]]):format(options.content or '')
        elseif is_file(j) then
          output[scope][#output[scope] + 1] = ([[<script type="text/javascript" src="%s%s?%s"></script>
]]):format(base_path, j, lfs.attributes(j, 'modification'))
        end
      end
      output[scope] = tcon(output[scope])
    end
    return output
  end
end

do
  local css = {
    [('themes/%s/style.css'):format(settings.theme or 'basic')] = {},
  }
  function add_css(data, options)
    if options == nil then options = {} end
    if data ~= nil then
      css[data] = options
    end
  end

  function get_css()
    local output = {}
    for k, v in pairs(css) do
      if is_file(k) then
        rawset(output, #output + 1, ([[<link type="text/css" rel="stylesheet" media="all" href="%s%s?%s" />
]]):format(base_path, k, lfs.attributes(k, 'modification')))
      end
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

  redirect(dest_url, http_response_code)

  exit_ophal()
end

--[[
  Format given unix timestamp by system date format.
]]
function format_date(uts, date_format)
  return date(date_format and date_format or settings.date_format, uts)
end

function get_global(key)
  return env[key]
end

function set_global(key, value)
  env[key] = value
end
