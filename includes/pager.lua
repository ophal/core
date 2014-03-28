local tconcat = table.concat

function pager(route, num_pages, current_page)
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
    pages[#pages + 1] = l('Previous', ('%s?page=%s'):format(url(route), current_page - 1), {
      external = true,
      attributes = {rel = 'prev'},
    })
  end

  -- Build links to all pages
  for page = 1,num_pages do
    pages[#pages + 1] = page ~= current_page and
      l(page, url(route) .. '?page=' .. page, {external = true}) or
      page
  end

  -- Link to next page
  if current_page < num_pages then
    pages[#pages + 1] = l('Next', ('%s?page=%s'):format(url(route), current_page + 1), {
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
