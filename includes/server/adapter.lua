local text = require 'includes.text'
local trim, ltrim, rtrim = text.trim, text.ltrim, text.rtrim
local dirname, basename = seawolf.fs.dirname, seawolf.fs.basename
local empty = seawolf.variable.empty
local date = os.date
local char, tonumber, type = string.char, tonumber, type
local gmatch, tostring = string.gmatch, tostring

--[[ Percent-decoding, through nginx where nginx is available.

  `ngx.unescape_uri` is a C call and is 15x the `gsub`-with-a-callback below it:
  77 ns against 1,198 for a 26-byte value, measured 2026-09-10. It is called
  twice per query argument and twice per cookie, so it is the single hottest
  string operation on the request path.

  The pure-Lua spelling stays because this file is the *runtime adapter* and is
  loaded by the unit suite without an `ngx`. Both are pinned in
  `tests/unit/test_request_parsing.lua`.

  Note `ngx.unescape_uri` also turns `+` into a space, which is the
  query-string rule -- so the two spellings agree only when `plus_as_space` is
  true. The cookie path below does not want that and does not take it.
]]
local unescape_uri

local decode_args

if ngx ~= nil and type(ngx.unescape_uri) == 'function' then
  unescape_uri = ngx.unescape_uri
end

if ngx ~= nil and type(ngx.decode_args) == 'function' then
  decode_args = ngx.decode_args
end

ophal.runtime = ophal.runtime or {}
local runtime = ophal.runtime

local function decode_percent(value)
  return (value:gsub('%%(%x%x)', function(hex)
    local byte = tonumber(hex, 16)

    if byte == nil then
      return '%' .. hex
    end

    return char(byte)
  end))
end

local function decode_component(value, plus_as_space)
  value = tostring(value or '')

  if plus_as_space then
    if unescape_uri ~= nil then
      return unescape_uri(value)
    end

    value = value:gsub('%+', ' ')
  end

  return decode_percent(value)
end

local function split_pair(value)
  local idx = tostring(value or ''):find('=', 1, true)

  if idx == nil then
    return value or '', ''
  end

  return value:sub(1, idx - 1), value:sub(idx + 1)
end

function server_register_adapter(name, adapter)
  runtime.adapter_name = name
  runtime.adapter = adapter
  ophal.request = nil

  if adapter and adapter.init then
    adapter.init(env, settings)
  end

  return adapter
end

function server_get_adapter()
  if runtime.adapter == nil then
    error 'server: no active runtime adapter'
  end

  return runtime.adapter
end

--[[ This request's parsed request table, built once and remembered.

  It is remembered on `ophal`, which is request state, and not on `runtime`,
  which is the worker's. Two requests in flight in one worker would otherwise
  share one entry: the second to arrive would install its own table and the
  first would resume reading the second's method, path, cookies and body.
]]
function server_get_request(reset)
  if reset then
    ophal.request = nil
  end

  if ophal.request == nil then
    ophal.request = server_get_adapter().request()
  end

  return ophal.request
end

--[[ Ophal's `_GET`: every argument a string, last one wins.

  `ngx.decode_args` is a C call and is 13x the hand-rolled parser this replaced
  -- 636 ns against 8,374 for a four-argument query string, measured
  2026-09-10. It answers a shape `_GET` consumers do not expect, though, so it
  is normalized here rather than at ninety call sites:

  - **A valueless argument** (`?flag`) decodes to the boolean `true`. Every
    consumer here treats a query argument as a string, so it becomes `''` --
    which is what the old parser produced, because `split_pair` returned an
    empty value for a pair with no `=`.
  - **A repeated argument** (`?page=1&page=2`) decodes to a *table*. The old
    parser overwrote, so the last one won; take the last element to keep that.
    Handing a table to `tonumber` in `pager_current_page()` would answer nil,
    which is a different page rather than an error.

  The 100-argument cap is `ngx.decode_args`'s default and it is **kept on
  purpose**. A query string is request input and this table is built from it,
  so an unbounded one is an unbounded allocation; past the cap the extra
  arguments are dropped rather than raising, which is the safe direction for
  something nothing legitimate reaches.
]]
local function normalize_arg(value)
  if value == true then
    return ''
  end

  if type(value) == 'table' then
    local last = value[#value]

    return last == true and '' or tostring(last or '')
  end

  return value
end

function server_parse_query(query_string)
  local parsed = {}

  if empty(query_string) then
    return parsed
  end

  if decode_args ~= nil then
    for key, value in pairs(decode_args(query_string)) do
      parsed[key] = normalize_arg(value)
    end

    return parsed
  end

  -- No `ngx`: the unit suite loads this file directly. Same answers, slower.
  for pair in gmatch(tostring(query_string) .. '&', '([^&]*)&') do
    if #pair > 0 then
      local key, value = split_pair(pair)

      parsed[decode_component(key, true)] = decode_component(value, true)
    end
  end

  return parsed
end

--[[ Ophal's cookie jar.

  nginx has no primitive for `Cookie`, so this stays hand-rolled -- but on
  `gmatch` rather than a per-call LPeg grammar.

  **Values are percent-decoded without plus-as-space**, which is the change
  from the parser this replaced. `+` meaning a space is the
  `application/x-www-form-urlencoded` rule; RFC 6265 has no such rule, so a
  cookie value holding a `+` came back holding a space. Nothing Ophal stores in
  a cookie is affected -- a session id is hex and dashes -- but a module keeping
  a base64 value in one would have been, silently and only for some values.
]]
function server_parse_cookies(cookie_string)
  local parsed = {}

  if empty(cookie_string) then
    return parsed
  end

  for pair in gmatch(tostring(cookie_string) .. ';', '([^;]*);') do
    local trimmed = trim(pair)

    if #trimmed > 0 then
      local key, value = split_pair(trimmed)

      parsed[decode_component(key)] = decode_component(value)
    end
  end

  return parsed
end

function server_build_request_uri(server_getter, script_name, query_string)
  local uri = server_getter 'REQUEST_URI'

  if uri == nil then
    if not empty(query_string) then
      uri = (script_name or '') .. '?' .. query_string
    else
      uri = script_name or ''
    end
  end

  return '/' .. ltrim(uri or '', '/')
end

function server_normalize_path(uri, script_name)
  local request_path = decode_component((uri or ''):match('^[^?]*') or '')
  local script_dir = rtrim(dirname(script_name or '/index.lua'), '\\/')
  local path = request_path:sub(script_dir:len() + 1)
  local script = basename(script_name or '/index.lua')

  if path == script or path == '/' .. script then
    path = ''
  elseif script ~= '' then
    if path:sub(1, #script + 1) == script .. '/' then
      path = path:sub(#script + 2)
    elseif path:sub(1, #script + 2) == '/' .. script .. '/' then
      path = path:sub(#script + 3)
    end
  end

  return trim(path, '/')
end

function server_cookie_string(name, value, options)
  options = options or {}

  local output = {('%s=%s'):format(name or '', value or '')}
  local expires = options.expires

  if not empty(options.domain) then
    output[#output + 1] = 'domain=' .. options.domain
  end

  if not empty(expires) then
    if type(expires) == 'number' then
      expires = date('!%a, %d-%b-%Y %X GMT', expires)
    end
    output[#output + 1] = 'expires=' .. expires
  end

  if not empty(options.path) then
    output[#output + 1] = 'path=' .. options.path
  end

  if not empty(options.same_site) then
    output[#output + 1] = 'SameSite=' .. options.same_site
  end

  if options.secure then
    output[#output + 1] = 'Secure'
  end

  if options.http_only then
    output[#output + 1] = 'HttpOnly'
  end

  return table.concat(output, '; ')
end

function server_parse_status(status)
  if status == nil then
    return nil
  elseif type(status) == 'number' then
    return status
  end

  return tonumber((tostring(status):match '^%d+'))
end
