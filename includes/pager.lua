local tconcat = table.concat
local seawolf = require 'seawolf'.__build('contrib')

function pager_url(path, page, selector)
  local result = seawolf.contrib.seawolf_table()

  result:append(url(path))

  if page > 1 then
    result:append{'?page=', page}
  end

  if selector then
    result:append{'#', selector}
  end

  return result:concat()
end

function pager(route, num_pages, current_page, selector)
  if nil == current_page then
    current_page = 1
  elseif type(current_page) ~= 'number' then
    current_page = tonumber(current_page)
  end

  local pages = {}

  if num_pages <= 1 then
    return pages
  end
  -- Link to previous page
  if current_page > 1 then
    pages[#pages + 1] = l('previous', pager_url(route, current_page - 1, selector), {
      external = true,
      attributes = {rel = 'prev'},
    })
  end

  -- Build links to all pages
  for page = 1,num_pages do
    pages[#pages + 1] = page ~= current_page and
      l(page, pager_url(route, page, selector), {external = true}) or
      page
  end

  -- Link to next page
  if current_page < num_pages then
    pages[#pages + 1] = l('next', pager_url(route, current_page + 1, selector), {
      external = true,
      attributes = {rel = 'next'},
    })
  end

  return pages
end

function theme.pager(variables)
  if variables == nil then variables = {} end

  local pages = variables.pages ~= nil and variables.pages or {}

  if #pages > 0 then
    return '<nav role="navigation" class="pager">' .. tconcat(pages or {}, ' ') .. '</nav>'
  end
end
