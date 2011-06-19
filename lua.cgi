#!/usr/bin/env luajit

print [[Content-type: text/html; charset=utf-8
]]

function include(file)
  -- read the whole contents of the file
  local fh = assert(open(file))
  local src = 'print [[' .. fh:read([[*a]]) .. ']]'
  fh:close()
  -- translates the file into a function
  local prog = loadstring(src)
  setfenv (prog, env)
  local status, err = pcall(prog)
  if not status then
    print [[<strong>]]; print(err); print[[</strong>]]
  end
end

--[[ TODO
- Use hook:bootstrap to allow modules call its dependencies when needed,
- Use hook:bootstrap to fill the list of Ophal modules to load, 
- Use hook:environment to fill the list of Lua functions to load, modules call its dependencies when needed,
- Optionally (setting based), build a cache of dependencies based on path
]]

env = {open = io.open, pcall = pcall, loadstring = loadstring, setfenv = setfenv, assert = assert, print = print, include = include}
env.env = env

setfenv(include, env)

include([[index.html]])
