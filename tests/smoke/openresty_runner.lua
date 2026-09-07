package.path = './?.lua;./?/init.lua;' .. package.path

local function render(lines)
  return table.concat(lines, '\n') .. '\n'
end

local function query_arg(name)
  local value = _GET and _GET[name]

  if type(value) == 'table' then
    return value[1]
  end

  return value
end

local function run_bootstrap(main)
  require 'includes.bootstrap'
  return ophal.bootstrap(nil, main)
end

local function get_scenario()
  local args = ngx.req.get_uri_args()
  local scenario = args.scenario

  if type(scenario) == 'table' then
    return scenario[1]
  end

  return scenario
end

local scenarios = {
  -- Proves the `lua_shared_dict` name declared in nginx.conf matches the name
  -- includes/projection.lua resolves. The module falls back to a per-worker
  -- table silently when they disagree, so only an end-to-end probe catches it.
  projection_shared_dict = function()
    return run_bootstrap(function()
      local projection = require 'includes.projection'
      local dict = ngx.shared.ophal_projection_versions

      -- Seed the zone directly, the way a peer worker publishing a version
      -- would, then read it back through the module. A name mismatch between
      -- nginx.conf and the module makes the read fall through to SQL instead.
      if dict then
        dict:set('smoke_probe', 12345)
      end

      write(render{
        'SMOKE_DICT_DECLARED=' .. tostring(dict ~= nil),
        'SMOKE_DICT_VERSION=' .. tostring(projection.version('smoke_probe')),
      })
    end)
  end,
  -- Reports the worker's cumulative query counters. It deliberately does not
  -- bootstrap: a probe that connected to the database would add queries to the
  -- number it exists to report. With `lua_code_cache on` and one worker this
  -- reads the very table `db_query()` counts into, so the difference between
  -- two probes is exactly what the requests between them cost.
  db_stats = function()
    local stats = require 'includes.database.stats'
    local snapshot = stats.snapshot()
    local lines = {
      'SMOKE_DB_TOTAL=' .. tostring(snapshot.total),
      'SMOKE_DB_NORMALIZED=' .. tostring(snapshot.normalized),
      'SMOKE_DB_PROJECTION=' .. tostring(snapshot.projection),
      'SMOKE_DB_INFRASTRUCTURE=' .. tostring(snapshot.infrastructure),
    }
    local names = {}

    for name in pairs(snapshot.tables) do
      names[#names + 1] = name
    end
    table.sort(names)

    for _, name in ipairs(names) do
      lines[#lines + 1] = ('SMOKE_DB_TABLE_%s=%s'):format(name, snapshot.tables[name])
    end

    ngx.print(render(lines))
  end,
  request_metadata = function()
    return run_bootstrap(function()
      write(render{
        'SMOKE_URI=' .. (request_uri() or ''),
        'SMOKE_URI_NO_QUERY=' .. (request_uri(true) or ''),
        'SMOKE_PATH=' .. (request_path() or ''),
        'SMOKE_QUERY_FOO=' .. (_GET.foo or ''),
      })
    end)
  end,
  request_body_get = function()
    return run_bootstrap(function()
      write(render{'SMOKE_BODY_IS_NIL=' .. tostring(request_get_body() == nil)})
    end)
  end,
  request_body_post = function()
    return run_bootstrap(function()
      write(render{'SMOKE_BODY=' .. (request_get_body() or '')})
    end)
  end,
  redirect_goto = function()
    return run_bootstrap(function()
      go_to('lorem_ipsum')
    end)
  end,
  cookie_append = function()
    return run_bootstrap(function()
      cookie_set('alpha', '1', 60, base.route, get_cookie_domain())
      cookie_set('beta', '2', 60, base.route, get_cookie_domain())
      write(render{'SMOKE_COOKIE_APPEND=ok'})
    end)
  end,
  output_buffering = function()
    return run_bootstrap(function()
      header('x-smoke', 'buffered')
      write(render{'SMOKE_BUFFERED_OUTPUT=ok'})
    end)
  end,
  csrf_token = function()
    return run_bootstrap(function()
      write(render{'SMOKE_CSRF_TOKEN=' .. (csrf_token() or '')})
    end)
  end,
  file_upload_chunk = function()
    return run_bootstrap(function()
      local body = request_get_body() or ''
      local output = ophal.modules.file.upload_service()

      write(render{
        'SMOKE_UPLOAD_SUCCESS=' .. tostring(output and output.success == true),
        'SMOKE_UPLOAD_ERROR=' .. tostring(output and output.error or ''),
        'SMOKE_UPLOAD_BODY=' .. body,
      })
    end)
  end,
  file_merge_chunks = function()
    return run_bootstrap(function()
      local output = ophal.modules.file.merge_service()
      local file_path = ((settings.site or {}).files_path or '') .. '/' .. (query_arg('name') or '')
      local handle = io.open(file_path, 'r')
      local stored = handle and handle:read('*a') or ''

      if handle then
        handle:close()
      end

      write(render{
        'SMOKE_MERGE_SUCCESS=' .. tostring(output and output.success == true),
        'SMOKE_MERGE_ERROR=' .. tostring(output and output.error or ''),
        'SMOKE_MERGED_FILE=' .. stored,
      })
    end)
  end,
}

local scenario = get_scenario()
assert(scenario and scenario ~= '', 'missing smoke scenario')

local runner = scenarios[scenario]
assert(runner, ('unknown smoke scenario: %s'):format(scenario))
return runner()
