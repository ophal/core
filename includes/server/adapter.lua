local explode = seawolf.text.explode
local trim, ltrim, rtrim = seawolf.text.trim, seawolf.text.ltrim, seawolf.text.rtrim
local dirname, basename = seawolf.fs.dirname, seawolf.fs.basename
local empty = seawolf.variable.empty
local date = os.date
local char, tonumber = string.char, tonumber

ophal.runtime = ophal.runtime or {}
local runtime = ophal.runtime

local function decode_component(value, plus_as_space)
  value = tostring(value or '')

  if plus_as_space then
    value = value:gsub('+', ' ')
  end

  return (value:gsub('%%(%x%x)', function(hex)
    local byte = tonumber(hex, 16)

    if byte == nil then
      return '%' .. hex
    end

    return char(byte)
  end))
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
  runtime.request = nil

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

function server_get_request(reset)
  if reset then
    runtime.request = nil
  end

  if runtime.request == nil then
    runtime.request = server_get_adapter().request()
    ophal.request = runtime.request
  end

  return runtime.request
end

function server_parse_query(query_string)
  local parsed = {}
  local list = explode('&', query_string or '')

  if list then
    local key, value
    for _, v in pairs(list) do
      if #v > 0 then
        key, value = split_pair(v)
        key = decode_component(key, true)
        value = decode_component(value, true)
        parsed[key] = value
      end
    end
  end

  return parsed
end

function server_parse_cookies(cookie_string)
  local parsed = {}
  local cookies = explode(';', cookie_string or '')

  if cookies then
    local key, value
    for _, v in pairs(cookies) do
      v = trim(v)
      if #v > 0 then
        key, value = split_pair(v)
        key = decode_component(key, true)
        value = decode_component(value, true)
        parsed[key] = value
      end
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
