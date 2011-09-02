function page_set_title(title)
  ophal.title = (title and title .. [[ | ]] or [[]]) .. settings.site_name
end