local tconcat, floor = table.concat, math.floor
local util = require 'includes.util'

--[[ `util.concat_deep` rather than `table.concat`, because the parts below are
  nested: `{'?page=', page}` is a table, and flattening it is what turns it back
  into `?page=2`. That descent is the one behaviour of seawolf's table metatable
  Ophal actually depended on.
]]
function pager_url(path, page, selector)
  local result = {url(path)}

  if page > 1 then
    result[#result + 1] = {'?page=', page}

    if selector then
      result[#result + 1] = {'#', selector}
    end
  end

  return util.concat_deep(result)
end

-- Normalize a caller-supplied `?page=` value into a whole page number within
-- `1 .. num_pages`. Listing pages feed the result into projection payload cache
-- keys, so an unclamped value lets any visitor mint an unbounded number of
-- per-worker cache entries by walking the query string.
function pager_current_page(page, num_pages)
  local last = tonumber(num_pages)

  -- `last ~= last` is the NaN test; `ceil(count/ipp)` yields NaN for 0/0.
  if last == nil or last ~= last or last < 1 then
    last = 1
  else
    last = floor(last)
  end

  page = tonumber(page)

  if page == nil or page ~= page then
    return 1
  end

  page = floor(page)

  if page < 1 then
    return 1
  elseif page > last then
    return last
  end

  return page
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
