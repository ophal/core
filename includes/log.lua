local levels = {
  debug = 10,
  info = 20,
  notice = 25,
  warning = 30,
  error = 40,
  critical = 50,
}

local aliases = {
  warn = 'warning',
  err = 'error',
  crit = 'critical',
}

local ngx_levels = {
  debug = 'DEBUG',
  info = 'INFO',
  notice = 'NOTICE',
  warning = 'WARN',
  error = 'ERR',
  critical = 'CRIT',
}

local function config()
  local cfg = settings and (settings.logging or settings.log) or {}

  if cfg == false then
    return {enabled = false}
  elseif type(cfg) ~= 'table' then
    return {}
  end

  return cfg
end

local function normalize_level(level)
  level = aliases[level] or level or 'info'

  if levels[level] == nil then
    level = 'info'
  end

  return level
end

local function should_log(level)
  local cfg = config()
  local minimum

  if cfg.enabled == false then
    return false
  end

  minimum = normalize_level(cfg.level or 'warning')
  return levels[normalize_level(level)] >= levels[minimum]
end

local function encode_value(value)
  if type(value) == 'number' or type(value) == 'boolean' then
    return tostring(value)
  end

  value = tostring(value or '')
  value = value:gsub('\\', '\\\\')
  value = value:gsub('\n', '\\n')
  value = value:gsub('\r', '\\r')
  value = value:gsub('"', '\\"')

  return '"' .. value .. '"'
end

local function sorted_keys(context)
  local keys = {}

  if type(context) == 'table' then
    for key, value in pairs(context) do
      if value ~= nil then
        keys[#keys + 1] = key
      end
    end
  end

  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
  return keys
end

function log_format(level, message, context)
  local fields = {
    'time=' .. encode_value(os.date('!%Y-%m-%dT%H:%M:%SZ')),
    'level=' .. encode_value(normalize_level(level)),
    'message=' .. encode_value(message),
  }

  for _, key in ipairs(sorted_keys(context)) do
    fields[#fields + 1] = tostring(key) .. '=' .. encode_value(context[key])
  end

  return table.concat(fields, ' ')
end

local function default_writer(level, line)
  local ngx_level_name

  if ngx and ngx.log then
    ngx_level_name = ngx_levels[normalize_level(level)] or 'INFO'
    return ngx.log(ngx[ngx_level_name] or ngx.INFO, line)
  end

  if io and io.stderr then
    return io.stderr:write(line .. '\n')
  end
end

function log_event(level, message, context)
  local cfg = config()
  local normalized = normalize_level(level)
  local line

  if not should_log(normalized) then
    return false
  end

  line = log_format(normalized, message, context)

  if type(cfg.writer) == 'function' then
    cfg.writer(normalized, line, context or {})
  else
    default_writer(normalized, line)
  end

  return true
end

function log_debug(message, context)
  return log_event('debug', message, context)
end

function log_info(message, context)
  return log_event('info', message, context)
end

function log_notice(message, context)
  return log_event('notice', message, context)
end

function log_warn(message, context)
  return log_event('warning', message, context)
end

function log_error(message, context)
  return log_event('error', message, context)
end

function log_exception(message, err, context)
  context = context or {}
  context.error = tostring(err or '')

  if (config().tracebacks == true) and debug and type(debug.traceback) == 'function' then
    context.traceback = debug.traceback(context.error, 2)
  end

  return log_error(message, context)
end
