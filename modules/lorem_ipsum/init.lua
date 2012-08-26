local path_register_alias, url, theme = path_register_alias, url, theme
local page_set_title, l = page_set_title, l
local _SESSION, format, tonumber = _SESSION, string.format, tonumber

module [[ophal.modules.lorem_ipsum]]

--[[
  Implementation of hook_init().
]]
function init()
  path_register_alias([[lorem_ipsum]], [[loremipsum]])
end

--[[
  Implementation of hook_menu().
]]
function menu()
  local items = {}
  items.lorem_ipsum = {
    title = [[Lorem Ipsum]],
    page_callback = [[page]],
  }
  return items
end

function page()
  local title = l([[Lorem Ipsum]], [[lorem_ipsum]])

  page_set_title([[Lorem Ipsum]], title)

  return theme{[[lorem_ipsum]]}
end

function theme.lorem_ipsum()
  local counter = [[]]
  if _SESSION then
    _SESSION.lorem_ipsum_counter = (_SESSION.lorem_ipsum_counter or 0) + 1
    counter = format([[<p>This page has been shown %s times.</p>]], _SESSION.lorem_ipsum_counter)
  end
  return [[<p>Lorem ipsum dolor sit amet, consectetur adipiscing elit. In tristique arcu sit amet nulla semper cursus. Pellentesque ut augue dui. Suspendisse ac turpis id ante gravida aliquet sed sed nisi. Fusce nec bibendum purus. Vivamus blandit ultrices magna, nec ultrices nulla ullamcorper ac. Donec eu tellus sit amet orci pharetra pharetra vitae vitae tortor. Etiam et ante vel urna mollis iaculis nec eu quam. Proin purus lectus, malesuada id hendrerit ut, pellentesque a justo. Vivamus eget magna risus, sit amet vulputate tellus. In dictum dapibus lorem, in mattis enim dapibus in. Praesent iaculis, nisl nec consequat viverra, libero purus lacinia mi, in condimentum est nisi eu lorem. Maecenas adipiscing aliquam sem, id convallis nunc imperdiet eget. Vestibulum quis sapien sodales eros ultricies adipiscing. Aliquam erat volutpat. Proin venenatis purus eget metus mattis feugiat.</p>

<p>Ut luctus, orci vitae rhoncus semper, odio ante commodo erat, non pellentesque ipsum odio id arcu. Morbi congue libero nec nunc lobortis sit amet pretium turpis semper. Aliquam erat volutpat. Vestibulum scelerisque varius pulvinar. Etiam molestie diam et lorem sodales tristique. Ut sit amet erat urna. Morbi aliquam vulputate metus vitae dapibus. Ut viverra consectetur nisl eu fermentum. Nunc malesuada rhoncus ante, sed lacinia enim euismod vel. Integer accumsan velit dui, sit amet mattis nulla. In ac felis at magna suscipit auctor ut quis neque. Aliquam cursus gravida egestas.</p>

<p>Morbi placerat viverra dui, vitae malesuada enim varius at. Donec hendrerit nisl sed ligula iaculis ornare. Donec fringilla vestibulum tristique. Pellentesque eget dui lorem, bibendum consectetur enim. Quisque consequat libero quis enim laoreet condimentum. Etiam sem felis, accumsan at accumsan eget, ultrices ac nulla. Etiam in mollis dolor. Ut a leo nibh. Praesent quis odio et dolor pulvinar adipiscing. Praesent ut sapien sit amet sem pulvinar interdum. Nullam accumsan imperdiet nisi. Pellentesque sodales magna vel tortor eleifend ac molestie dolor mollis. Praesent viverra mollis urna, eget pretium nulla congue nec. Curabitur neque elit, porttitor sit amet pharetra ac, vehicula rutrum lacus.</p>]] ..
  counter
end

