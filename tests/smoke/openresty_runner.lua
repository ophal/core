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
