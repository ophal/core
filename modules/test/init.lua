local theme, add_js = theme, add_js

module 'ophal.modules.test'

--[[ Implements hook route().
]]
function route()
  local items = {}

  items['upload-test'] = {
    title = 'Upload a file',
    page_callback = 'upload_test_page',
  }

  return items
end

function upload_test_page()
  add_js 'misc/jquery.min.js'
  add_js 'misc/uuid.js'
  add_js 'modules/file/file.js'
  return
    '<div>' ..
      theme{'file'} ..
    '</div>'
end
