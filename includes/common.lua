local pairs, tcon, date, time = pairs, table.concat, os.date, os.time
local floor, ceil = math.floor, math.ceil
local lfs, json = lfs, require 'includes.json'

--[[ Half-away-from-zero rounding, to `places` decimals.

  This was `seawolf.maths.round`, and it was **nil at runtime**: `seawolf.maths`
  requires an undeclared rock named `random` at its first line, `__build`'s
  `pcall` stores the resulting error *string* in the slot rather than leaving it
  nil, and indexing a string is legal -- so `round` silently resolved to nil and
  `format_size()` raised "attempt to call a nil value" on every call.
  `theme.file_info` renders it, so a file's size has never displayed.
]]
local function round(value, places)
  local scale = 10 ^ (places or 0)

  if value >= 0 then
    return floor(value * scale + 0.5) / scale
  end

  return ceil(value * scale - 0.5) / scale
end
local str_replace = require('includes.text').replace
local request_state = require 'includes.request_state'

if type(html_url_escape) ~= 'function' then
  pcall(require, 'includes.escape')
end

function page_set_title(header_title, title)
  if header_title then
    if title == nil then title = header_title end

    if html_is_safe(title) then
      ophal.title = html_unwrap(title)
    else
      ophal.title = html_escape(title)
    end

    if html_is_safe(header_title) then
      header_title = html_unwrap(header_title)
    else
      header_title = html_escape(header_title)
    end

    ophal.header_title = (header_title and header_title .. ' | ' or '') .. html_escape(settings.site.name)
  else
    ophal.header_title = html_escape(settings.site.name)
  end
end

function page_not_found()
  header('status', 404)
  page_set_title 'Page not found.'
  return ''
end

do
  local asset_stat_cache = {}

  local function asset_cache_ttl()
    local runtime_cache = settings.runtime_cache or {}
    local ttl = tonumber(runtime_cache.asset_stat_ttl)

    if ttl == nil then
      ttl = tonumber(runtime_cache.file_stat_ttl)
    end

    if ttl == nil then
      ttl = tonumber(runtime_cache.stat_ttl)
    end

    if ttl == nil then
      ttl = 1
    end

    return ttl
  end

  function asset_cache_clear()
    asset_stat_cache = {}
  end

  local function asset_stat(path)
    local cached = asset_stat_cache[path]
    local ttl = asset_cache_ttl()
    local now = time()
    local attr

    if cached and ttl ~= 0 and now - cached.checked_at < ttl then
      return cached.attr
    end

    attr = lfs.attributes(path)
    asset_stat_cache[path] = {
      attr = attr,
      checked_at = now,
    }

    return attr
  end

  local function asset_url(path)
    local attr = asset_stat(path)

    if attr ~= nil and attr.mode == 'file' then
      return base.route .. path .. '?' .. attr.modification
    end
  end

  function common_asset_url(path)
    return asset_url(path)
  end
end

do
  --[[ The scripts this request has asked for.

    In request state rather than in three file upvalues. The accumulators are
    filled across the whole of a request -- `init_js()` at reset, modules while
    they render, the theme at the end -- so a worker that yields in between
    would otherwise merge two visitors' pages into one script list.
  ]]
  local function js_state()
    local state = request_state.current()

    if state.js == nil then
      state.js = {javascript = {}, order = {}, load_ophal_js = false}
    end

    return state.js
  end

  add_js = {}

  setmetatable(add_js, {
    __call = function(t, options)
      local js = js_state()
      local javascript, order = js.javascript, js.order

      js.load_ophal_js = true

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
        if not javascript[scope][data] then
          order[scope][#order[scope] + 1] = data
        end
        javascript[scope][data] = options
      end
    end
  })


  function init_js()
    local js = js_state()

    js.javascript = {}
    js.order = {}
    js.load_ophal_js = false

    add_js 'libraries/jquery.min.js'
    add_js 'libraries/ophal.js'
    add_js {type = 'settings', {base = base}}
    --[[ Registered here, minted in `get_js()`.

      `csrf_token()` writes into `_SESSION` when the session has no token yet,
      and `init_js()` runs on every request -- so calling it here gave every
      anonymous visitor a session file, a lock file and a `Set-Cookie` for a
      value most pages never emit. Note the line below this block: `init_js()`
      ends by setting `load_ophal_js` back to false, so a page that adds no
      script of its own returns '' from `get_js()`. The token was minted,
      written to disk and thrown away unread.

      The guard stays exactly where it was -- `includes/security.lua` is
      required after this file in bootstrap phase 9 -- and only the value moves.
    ]]
    if type(csrf_token) == 'function' then
      add_js {type = 'settings', csrf = true, {}}
    end
    add_js {type = 'settings', namespace = 'locale', settings.locale}
    js.load_ophal_js = false

    for _, v in pairs(theme.settings.js or {}) do
      add_js(v)
    end
  end

  function get_js()
    local js = js_state()
    local javascript, order = js.javascript, js.order

    if not js.load_ophal_js then
      return ''
    end

    local output = {}

    for scope, v in pairs(order) do
      output[scope] = {}
      for _, j in pairs(v) do
        local options = javascript[scope][j]
        local asset_url
        if options ~= nil and options.type == 'settings' then
          -- Deferred by `init_js()`: this is the first point at which the token
          -- is certain to be rendered, so it is the first point at which a
          -- session has to exist to hold it.
          if options.csrf and type(csrf_token) == 'function' then
            j.csrf_token = csrf_token()
          end
          output[scope][#output[scope] + 1] = ([=[<script type="text/javascript">
<!--//--><![CDATA[//><!--
(function ($) {
$.extend(true, Ophal.settings, {%s: %s});
})(jQuery);
//--><!]]>
</script>
]=]):format(
            ('"%s"'):format(js_escape_string(options.namespace or 'core')),
            -- A JS settings namespace is an object, and it says so. dkjson
            -- writes `[]` for an empty table and cjson writes `{}`, and
            -- `$.extend(true, Ophal.settings, {core: []})` is not what any of
            -- this means -- so the shape is stated here rather than inherited
            -- from whichever backend resolved.
            js_escape_json(json.encode(json.object(j)) or '')
          )
        elseif options ~= nil and options.type == 'inline' then
          output[scope][#output[scope] + 1] = ([=[<script type="text/javascript">
<!--//--><![CDATA[//><!--
%s
//--><!]]>
</script>
]=]):format(j or '')
        elseif options ~= nil and options.type == 'external' then
          output[scope][#output[scope] + 1] = ([[<script type="text/javascript" src="%s"></script>
]]):format(html_url_escape(j or ''))
        else
          asset_url = common_asset_url(j)
        end

        if asset_url then
          output[scope][#output[scope] + 1] = ([[<script type="text/javascript" src="%s"></script>
]]):format(html_url_escape(asset_url))
        end
      end
      output[scope] = tcon(output[scope])
    end
    return output
  end
end

do
  local function css_state()
    local state = request_state.current()

    if state.css == nil then
      state.css = {}
    end

    return state.css
  end

  function init_css()
    local css = {}

    request_state.current().css = css

    css[('themes/%s/style.css'):format(theme.name)] = {}

    for _, v in pairs(theme.settings.css or {}) do
      css[v:format(theme.name)] = {}
    end
  end

  function add_css(data, options)
    if options == nil then options = {} end
    if data ~= nil then
      css_state()[data] = options
    end
  end

  function get_css()
    local output = {}
    for k, v in pairs(css_state()) do
      local asset_url = common_asset_url(k)
      if asset_url then
        output[1 + #output] = ([[<link type="text/css" rel="stylesheet" media="all" href="%s" />
]]):format(html_url_escape(asset_url))
      end
    end
    return tcon(output)
  end
end

do
  local function head_state()
    local state = request_state.current()

    if state.head == nil then
      state.head = {}
    end

    return state.head
  end

  function init_head()
    local head = {}

    request_state.current().head = head

    for k, v in pairs(theme.settings.head or {}) do
      head[k] = v
    end
  end

  function add_head(data)
    local head

    if data ~= nil then
      head = head_state()
      head[#head + 1] = data
    end
  end

  function get_head()
    return tcon(head_state(), [[

]])
  end
end

function common_reset_request()
  if type(theme) == 'table' and theme.settings then
    init_head()
    init_css()
    init_js()
  end
end

function shutdown_ophal()
  -- call hook exit
  if module_invoke_all then
    module_invoke_all 'exit'
  end

  -- destroy session (phase end)
  if settings.sessionapi and session_write_close then
    session_write_close()
  end

  -- Give back every connection this request took, after the modules that might
  -- still have queried in their exit hooks. Under keepalive a socket belongs to
  -- one request: one that is not released never returns to the pool, and an
  -- object that outlives its release raises at its next use rather than
  -- reaching a socket another request now owns.
  if type(db_release_all) == 'function' then
    db_release_all(true)
  end
end

function exit_ophal()
  shutdown_ophal()

  -- flush output buffer
  if settings.output_buffering then
    output_flush()
  end

  -- “I’m history! No, I’m mythology! Nah, I don’t care what I am; I’m free
  -- hee!” - Genie, Aladdin | Robin Williams
  server_exit()
end

--[[
  Send the user to a different Ophal page.

  This issues an on-site HTTP redirect. The function makes sure the redirected
  URL is formatted correctly.

  This function ends the request; use it rather than a print theme('page')
  statement in your route callback.

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
function go_to(path, http_response_code, options)
  path = path or ''
  http_response_code = http_response_code or 302
  options = options or {}
  if options.absolute == nil then options.absolute = true end

  local dest_url

  dest_url = url(path, options)
  -- Remove newlines from the URL to avoid header injection attacks.
  dest_url = str_replace({'\n', '\r'}, '', dest_url)

  redirect(dest_url, http_response_code)

  exit_ophal()
end

_G['goto'] = go_to

--[[
  Format given unix timestamp by system date format.
]]
function format_date(uts, date_format)
  return date(date_format and date_format or settings.date_format, uts)
end


--[[ Format given file size in units.
]]
do
  local units = {'B', 'KB', 'MB', 'GB', 'TB', 'PB'}

  function format_size(size)
    size = size or 0

    local unit, scale

    for k, v in pairs(units) do
      unit = v
      scale = k - 1
      if 1024^k > size then
        break
      end
    end
    size = round(size/1024^scale, 2)
    return ('%s %s'):format(size, unit)
  end
end

function get_global(key)
  return env[key]
end

function set_global(key, value)
  env[key] = value
end
