package.path = './?.lua;./?/init.lua;' .. package.path

local function render(lines)
  return table.concat(lines, '\n') .. '\n'
end

--[[ One URI argument, read straight from nginx.

  Not from `_GET`. This function is created with the runner chunk's environment
  and `_GET` is set on the jailed environment bootstrap builds, so reading it
  here answered nil however the request was made -- silently, which is why
  `stale_projection` could take a `key` argument that never did anything.
]]
local function query_arg(name)
  local args = ngx.req.get_uri_args()
  local value = args and args[name]

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
  return query_arg('scenario')
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
  -- The queue, end to end. Registering the handler here and draining it from
  -- `/cron` works because both locations run in the same worker with
  -- `lua_code_cache on`, so `package.loaded` keeps one `includes.jobs` table
  -- with one handler registry across requests -- the same sharing the drain
  -- relies on in production, where a module registers its kinds at load time.
  --
  -- What the drain did is read back out of the database rather than out of a
  -- counter in this file. A `content_by_lua_file` chunk is re-executed on every
  -- request even with the code cache on, so a file-level local would be zero
  -- again by the time the next probe asked.
  -- Drags one projection's version behind its source, which is what a restore,
  -- a CLI write or a failed rebuild does on a real site. Version 1 is used
  -- rather than a future value on purpose: a rebuild stamps both keys with
  -- `time()`, so a version ahead of the clock would leave the projection stale
  -- forever and the queue spinning.
  stale_projection = function()
    return run_bootstrap(function()
      local projection = require 'includes.projection'
      local key = query_arg('key') or 'content_public'

      projection.touch(key, 1)

      write(render{
        'SMOKE_STALE_KEY=' .. key,
        'SMOKE_STALE_VERSION=' .. tostring(projection.version(key)),
      })
    end)
  end,
  jobs_enqueue = function()
    return run_bootstrap(function()
      local jobs = require 'includes.jobs'

      jobs.register('smoke_probe', function(payload)
        if not (payload and payload.marker == 'drained') then
          return false
        end

        db_query(
          'UPDATE ophal_jobs SET last_error = ? WHERE kind = ?',
          'smoke handler ran',
          'smoke_probe'
        )

        return true
      end)

      write(render{
        'SMOKE_JOBS_ENQUEUED=' .. tostring(
          jobs.enqueue('smoke_probe', 'smoke:probe', {marker = 'drained'})
        ),
        'SMOKE_JOBS_PENDING=' .. tostring(jobs.pending_count()),
      })
    end)
  end,
  jobs_status = function()
    return run_bootstrap(function()
      local jobs = require 'includes.jobs'
      local rs = db_query(
        'SELECT status, last_error FROM ophal_jobs WHERE kind = ? ORDER BY id',
        'smoke_probe'
      )
      local row = rs and rs:fetch()

      write(render{
        'SMOKE_JOBS_PENDING=' .. tostring(jobs.pending_count()),
        'SMOKE_JOBS_STATUS=' .. tostring(row and row[1] or ''),
        'SMOKE_JOBS_HANDLER=' .. tostring(row and row[2] or ''),
      })
    end)
  end,
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
