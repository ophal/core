function page_set_title(header_title, title)
  if header_title then
    if title == nil then title = header_title end
    ophal.title = title
    ophal.header_title = (header_title and header_title .. [[ | ]] or [[]]) .. settings.site.name
  else
    ophal.header_title = settings.site.name
  end
end

