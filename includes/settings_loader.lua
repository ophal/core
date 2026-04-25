local M = {}

local function default_settings()
  return {
    version = {
      core = true,
      number = true,
      revision = true,
    },
    slash = string.sub(package.config, 1, 1),
    modules = {},
    debugapi = true,
  }
end

local function apply_module_overrides(settings, overrides, vault)
  if type(overrides) == 'function' then
    overrides(settings, vault)
  elseif type(overrides) == 'table' then
    settings.modules = settings.modules or {}
    for name, enabled in pairs(overrides) do
      settings.modules[name] = enabled
    end
  end
end

function M.build(options)
  options = options or {}

  local settings = default_settings()
  local ok, vault = pcall(require, 'vault')
  if not ok then
    vault = nil
  end

  local ok_settings, settings_builder = pcall(require, 'settings')
  if ok_settings and type(settings_builder) == 'function' then
    settings_builder(settings, vault)
  end

  if options.include_module_overrides ~= false then
    package.loaded['settings.modules'] = nil
    local ok_overrides, module_overrides = pcall(require, 'settings.modules')

    if ok_overrides then
      apply_module_overrides(settings, module_overrides, vault)
    elseif not tostring(module_overrides or ''):match("module 'settings%.modules' not found") then
      error(module_overrides)
    end
  end

  return settings
end

return M
