local slash, theme_name = settings.slash, settings.theme
local pcall, settings, cursrentdir = pcall, settings, lfs.currentdir
local table, assert, error, setfenv = table, assert, error, setfenv
local currentdir = lfs.currentdir() .. slash

setmetatable(theme, {
  __call = function(t, f, args)
    if t[f] == nil then
      file = ([[%sthemes%s%s%s%s.tpl.html]]):format(currentdir, slash, theme_name, slash, f)

      local attr, err = lfs.attributes(file)
      if err then
        return ([[template '%s': %s]]):format(file, err)
      end

      if attr ~= nil and attr.mode == [[file]] then
        -- read file contents
        local fh = assert(io.open(file))
        local src = ('print [[%s]]'):format(fh:read([[*a]]))
        fh:close()

        -- load source code
        local prog, err = loadstring(src, file)
        if not prog then
          return ([[template '%s': %s]]):format(file, err)
        end

        -- jail
        args = args or {}
        args.print = print
        args.settings = settings
        args.echo = echo
        args.theme = theme
        setfenv(prog, args)

        -- execute
        local status, result = pcall(prog)
        if status then
          return [[]] -- TODO: return a buffered output of the template
        else
          return ([[template '%s': %s]]):format(file, err)
        end
      end
    else
      -- execute
      local status, result = pcall(t[f], unpack(args))
      if status then
        return result
      else
        return ([[theme function %s: '%s']]):format(f, result)
      end
    end
  end
})
