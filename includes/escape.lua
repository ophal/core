local allowed_url_schemes = {
  http = true,
  https = true,
  mailto = true,
  tel = true,
  ftp = true,
}

local function as_string(value)
  if type(value) == 'table' and value.__html == true then
    return tostring(value.value or '')
  end

  if value == nil then
    return ''
  end

  return tostring(value)
end

function html_safe(value)
  return {
    __html = true,
    value = as_string(value),
  }
end

function html_is_safe(value)
  return type(value) == 'table' and value.__html == true
end

function html_unwrap(value)
  return as_string(value)
end

function html_escape(value)
  value = as_string(value)
  value = value:gsub('&', '&amp;')
  value = value:gsub('<', '&lt;')
  value = value:gsub('>', '&gt;')

  return value
end

function html_attr_escape(value)
  value = html_escape(value)
  value = value:gsub('"', '&quot;')
  value = value:gsub("'", '&#39;')
  value = value:gsub('\r', '&#13;')
  value = value:gsub('\n', '&#10;')

  return value
end

function html_sanitize_url(value)
  local url = as_string(value)
  local stripped = url:gsub('^[%z\1-\32]+', '')
  local scheme = stripped:match('^([%w+.-]+):')

  if scheme and not allowed_url_schemes[scheme:lower()] then
    return '#'
  end

  return url:gsub('[\r\n]', '')
end

function html_url_escape(value)
  return html_attr_escape(html_sanitize_url(value))
end

function js_escape_json(value)
  value = as_string(value)
  value = value:gsub('</', '<\\/')
  value = value:gsub(']]>', ']]\\>')

  return value
end

function js_escape_string(value)
  value = as_string(value)
  value = value:gsub('\\', '\\\\')
  value = value:gsub('"', '\\"')
  value = value:gsub('\r', '\\r')
  value = value:gsub('\n', '\\n')

  return js_escape_json(value)
end
