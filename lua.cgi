#!/usr/bin/env luajit

--[[ Ophal v0.1-alpha1 ]]

print [[Content-type: text/html; charset=utf-8
]]

function include(file)
  file = table.concat({[[themes]], settings.slash, settings.theme, settings.slash, file}) 
  local attr, err = lfs.attributes(file)
  
  if attr ~= nil and attr.mode == [[file]] then
    -- read file contents
    local fh = assert(io.open(file))
    local src = 'print [[' .. fh:read([[*a]]) .. ']]'
    fh:close()

    -- load source code
    local prog = loadstring(src)
    setfenv (prog, env)

    -- execute
    local status, err = pcall(prog)
    if not status then
      print [[<strong>]]; print(err); print[[</strong>]]
    end
  else
    error(err)
  end
end

--[[ TODO
- Use hook:bootstrap to allow modules call its dependencies when needed,
- Use hook:bootstrap to fill the list of Ophal modules to load, 
- Use hook:environment to fill the list of Lua functions to load, modules call its dependencies when needed,
- Optionally (setting based), build a cache of dependencies based on path
]]

env = {io = {open = io.open, stderr = io.stderr}, pcall = pcall, loadstring = loadstring, setfenv = setfenv, assert = assert, print = function (s) io.write(s) end, table = table, require = require, error = error, lfs = require [[lfs]], include = include, settings = require [[settings]]}
env.env = env

setfenv(include, env)

include([[index.html]])
