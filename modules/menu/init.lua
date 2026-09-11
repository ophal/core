local module_invoke_all, empty, l = module_invoke_all, require('includes.util').empty, l
local tconcat, tinsert, theme, pairs = table.concat, table.insert, theme, pairs
local type, tsort, render_attributes = type, table.sort, render_attributes
local request_state = require 'includes.request_state'

local debug = debug

module 'ophal.modules.menu'

--[[ The menus, rebuilt per request rather than once per worker.

  They were a file-level table plus a `menus_build` flag, which made the whole
  menu **worker state decided by whichever request warmed the worker**. That is
  the shape `includes/mobile.lua` was deleted for and the one
  `get_user_roles()` was fixed for, and here it ran in the permissive
  direction: `modules/tag`'s `menus_alter()` adds a `Tags` link only when
  `user_mod.is_logged_in()`, so a worker whose first request was signed in
  served that link to every anonymous visitor afterwards -- and a worker warmed
  anonymously withheld it from everyone signed in. Under the `lua_code_cache
  on` that `nginx.ophal.conf` ships, "afterwards" is the rest of the worker's
  life.

  `db_author_menu_has_tags` is the assertion, and it was red before this: the
  anonymous scenario above it ran first and fixed the menu for the profile.

  Rebuilding also stops `theme.menu` below from eating its own definitions. It
  reads `label = v[1]` and then writes `v[1] = nil` -- harmless for a string
  entry, which is wrapped in a fresh table on the way in, and destructive for a
  table entry like `{'Label', weight = 3}`, which is the caller's own and would
  lose its label after one render. A per-request table bounds that damage to
  the request that did it.

  `request_state.current()` is `ngx.ctx` under OpenResty and one table in a
  standalone runtime, which is right for both: the CLI is one process per
  request. Same mechanism `includes/common.lua` keeps the script and stylesheet
  accumulators in, and for the same reason.
]]
local function build_menus()
  local menus = {
    primary_links = {
    }
  }

  module_invoke_all('menus_alter', menus)

  return menus
end

function get_menus(reset)
  local state = request_state.current()

  if reset or state.menus == nil then
    state.menus = build_menus()
  end

  return state.menus
end

function theme.menu(variables)
  local menu_id = variables.id
  local menu = get_menus()[menu_id] or {}

  local items = {}
  local output = {}

  local default_attributes = {
    id = 'menu_' .. menu_id,
  }
  local attributes = render_attributes(variables.attributes, default_attributes)

  if type(menu) == 'function' then
    menu = menu()
  end

  for route, v in pairs(menu) do
    if type(v) ~= 'table' then
      v = {v}
    end
    if v.weight == nil then
      v.weight = 0
    end

    local label, options
    label = v[1]
    v[1] = nil
    options = v

    tinsert(items, {l(label, route, options), weight = v.weight})
  end

  tsort(items, function (a, b)
    return a.weight < b.weight
  end)

  output = {
    '<nav', empty(attributes) and '' or ' ', attributes, '>',
    (function (items)
      local output = {}
      for k, v in pairs(items) do
        tinsert(output, v[1])
      end
      return tconcat(output, ' | ')
    end)(items),
    '</nav>',
  }

  return tconcat(output)
end
