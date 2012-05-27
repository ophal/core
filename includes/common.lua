local pairs, tcon, rawset = pairs, table.concat, rawset
local base_path = base_path

function page_set_title(header_title, title)
  if header_title then
    if title == nil then title = header_title end
    ophal.title = title
    ophal.header_title = (header_title and header_title .. [[ | ]] or [[]]) .. settings.site.name
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
