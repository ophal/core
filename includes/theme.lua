local slash, theme_name = settings.slash, settings.theme
local pcall, settings, cursrentdir = pcall, settings, lfs.currentdir
local table, assert, error, setfenv = table, assert, error, setfenv
local currentdir = lfs.currentdir() .. slash

setmetatable(theme, {
  __call = function(t, file, args)
    file = currentdir .. [[themes]] .. slash .. theme_name .. slash .. file .. [[.tpl.html]]
    if t[file] == nil then
      local attr, err = lfs.attributes(file)

      if attr ~= nil and attr.mode == [[file]] then
        -- read file contents
        local fh = assert(io.open(file))
        local src = 'print [[' .. fh:read([[*a]]) .. ']]'
        fh:close()

        -- load source code
        local prog, err = loadstring(src, file)
        if not prog then
          error(file .. [[: ]] .. err)
        end

        -- jail
        args = args or {}
        args.print = print
        args.settings = settings
        args.echo = echo
        args.theme = theme
        setfenv(prog, args)

        -- execute
        local status, err = pcall(prog)
        if not status then
          error(err)
        end
      else
        error(err)
      end
    end
  end
})
