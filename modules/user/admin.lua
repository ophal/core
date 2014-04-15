

module 'ophal.modules.user.admin'

--[[
  Implemens hook_route().
]]
function route()
  items = {}
  items['users'] = {
    title = 'User login',
    page_callback = 'users_page',
  }
  return items
end

function users()
  return theme.item_list{list = {}}
end
