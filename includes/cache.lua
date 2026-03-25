--[[ Unified cache clear.

  Clears all framework caches in one call: module list, routes,
  compiled templates, database schema, entity type info, and
  user permissions.  Each cache owner exposes its own clear function;
  this module simply calls them all.
]]
function cache_clear_all()
  -- Core caches
  if type(module_cache_clear) == 'function' then
    module_cache_clear()
  end
  if type(route_cache_clear) == 'function' then
    route_cache_clear()
  end
  if type(template_cache_clear) == 'function' then
    template_cache_clear()
  end
  if type(db_schema_cache_clear) == 'function' then
    db_schema_cache_clear()
  end

  -- Module caches
  local entity_mod = (ophal.modules or {}).entity
  if entity_mod and type(entity_mod.entity_type_info_cache_clear) == 'function' then
    entity_mod.entity_type_info_cache_clear()
  end
  local user_mod = (ophal.modules or {}).user
  if user_mod and type(user_mod.cache_clear) == 'function' then
    user_mod.cache_clear()
  end
end
