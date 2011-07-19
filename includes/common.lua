local table, assert, error, setfenv, pcall, settings, currentdir = table, assert, error, setfenv, pcall, settings, lfs.currentdir

function include(file)
  local attr, err = lfs.attributes(file)

  if attr ~= nil and attr.mode == [[file]] then
    -- read file contents
    local fh = assert(io.open(file))
    local src = 'print [[' .. fh:read([[*a]]) .. ']]'
    fh:close()

    -- load source code
    local prog, err = loadstring(src)
    if not prog then
      error(file .. [[: ]] .. err)
    end
    setfenv(prog, env)

    -- execute
    local status, err = pcall(prog)
    if not status then
      error(err)
    end
  else
    error(err)
  end
end