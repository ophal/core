function page_set_title(header_title, title)
  if title == nil then title = header_title end
  ophal.title = title
  ophal.header_title = (header_title and header_title .. [[ | ]] or [[]]) .. settings.site_name
end