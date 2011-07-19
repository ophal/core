local slash, theme_name = settings.slash, settings.theme
local currentdir = lfs.currentdir() .. slash

setmetatable(theme, {
  __call = function(t, file)
    if t[file] == nil then
      include(currentdir .. [[themes]] .. slash .. theme_name .. slash .. file .. [[.tpl.html]])
    end
  end
})
