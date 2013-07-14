if not ophal.aliases.source then ophal.aliases.source = {} end
if not ophal.aliases.alias then ophal.aliases.alias = {} end

local explode = seawolf.text.explode
local aliases = ophal.aliases

function path_register_alias(path, alias)
  aliases.source[path] = alias
  aliases.alias[alias] = path
end

do
  local arguments

  function arg(index)
    local alias, result

    index = index + 1

    if arguments == nil then
      q = request_path()
      arguments = explode('/', q ~= '' and q or settings.site.frontpage)
    end

    result = arguments[index]

    if result ~= nil then
      alias = aliases.alias[result]
      return alias and alias or result
    end
  end
end

local slash = settings.slash

do
  local path_tree, path
  function init_path()
    local alias

    if path_tree == nil and path == nil then
      path_tree, path = {}

      -- build path tree
      for i = 1,8 do
        a = arg(i - 1)
        if a == nil or a == '' then
          break
        else
          path = (path or '') .. (path and slash or '') .. (a or '')
          table.insert(path_tree, path)
        end
      end
      if not #path_tree then
        error 'Menu system error!'
      end
    end
    return path_tree, path
  end
end

function url(path, options)
  if options == nil then options = {} end
  if path == nil then path = '' end

  if not (options.alias or options.external) then
    alias = aliases.source[path]
    if alias then
      path = alias
    end
  end

  if options.external then
    return path
  end

  return (options.absolute and base_root or '') .. base_path .. path
end

function l(text, path, options)
  if options == nil then options = {} end

  local attributes = options.attributes or {}
  options.attributes = nil

  return theme{'a', 
    text = text,
    path = url(path, options),
    attributes = attributes,
  }
end
