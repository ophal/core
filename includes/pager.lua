local tconcat = table.concat

function pager(path, num_pages, current_page)
  if nil == current_page then
    current_page = 1
  end

  local pages = {}

  for page = 1,num_pages do
    rawset(pages, page,
      page ~= current_page and
        l(page, url(path) .. '?page=' .. page, {external = true}) or
        page
    )
  end

  return pages
end

function theme.pager(pages)
  return '<div class="pager">Page: ' .. tconcat(pages, ' ') .. '</div>'
end