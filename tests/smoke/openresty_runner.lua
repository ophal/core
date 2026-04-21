package.path = './?.lua;./?/init.lua;' .. package.path

local function render(lines)
  return table.concat(lines, '\n') .. '\n'
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
}

local scenario = get_scenario()
assert(scenario and scenario ~= '', 'missing smoke scenario')

local runner = scenarios[scenario]
assert(runner, ('unknown smoke scenario: %s'):format(scenario))
return runner()
