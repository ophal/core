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
  -- reads the very table the layer counts into, so the difference between
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
  -- Creates a route alias the way the authoring path does, so the suite can ask
  -- the only question the worker-held alias table really raises: does a worker
  -- that has stopped reading `route_index` still notice a write to it. A 404
  -- for a URL that exists is what that guard is holding back.
  create_alias = function()
    return run_bootstrap(function()
      local source = query_arg('source') or 'content/1'
      local alias = query_arg('alias') or 'late-alias'

      route_create_alias{source = source, alias = alias, language = 'all'}

      write(render{
        'SMOKE_ALIAS_CREATED=' .. alias,
        'SMOKE_ALIAS_SOURCE=' .. source,
      })
    end)
  end,
  -- What a site whose cron has never run looks like to the next request: the
  -- rebuild is still on the queue, and the marker that was suppressing further
  -- deferrals has lapsed. Backdating `created_at` to the epoch is the age; the
  -- marker is dropped rather than waited out, because the TTL is 900 seconds
  -- and the boundary itself is pinned in the unit tests.
  --
  -- `enqueue()` reports success for landing on that row exactly as it does for
  -- writing a new one, so without the age check the request that finds the
  -- marker gone re-marks and waits another full TTL, forever.
  stall_queue = function()
    return run_bootstrap(function()
      local projection = require 'includes.projection'
      local key = query_arg('key') or 'content_public'

      db_connection():execute(
        'UPDATE ophal_jobs SET created_at = 0 WHERE active_key = ?', key)
      projection.clear_pending(key)

      write(render{
        'SMOKE_STALL_KEY=' .. key,
        'SMOKE_STALL_PENDING=' .. tostring(projection.rebuild_pending(key)),
      })
    end)
  end,
  -- Reads one `file` row back. `filemime` is the field that matters: finalize
  -- leaves it null and the queue fills it in, so this is what tells the two
  -- halves apart from outside.
  file_row = function()
    return run_bootstrap(function()
      local entity = ophal.modules.file.load(query_arg('id'))

      write(render{
        'SMOKE_FILE_NAME=' .. tostring(entity and entity.filename or ''),
        'SMOKE_FILE_MIME=' .. tostring(entity and entity.filemime or ''),
        'SMOKE_FILE_SIZE=' .. tostring(entity and entity.filesize or ''),
      })
    end)
  end,
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

        db_connection():execute(
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
      local kind = query_arg('kind') or 'smoke_probe'
      -- Ad-hoc, because this is a probe rather than an application path: the
      -- statement exists only to look at what the queue did.
      local rs = db_connection():execute(
        'SELECT status, last_error FROM ophal_jobs WHERE kind = ? ORDER BY id',
        kind
      )
      -- Named, on every backend: two of the three drivers return rows as
      -- hashes and cannot answer positionally at all, so the layer promises
      -- only what all of them can keep.
      local row = rs and rs:fetch(true)

      write(render{
        'SMOKE_JOBS_PENDING=' .. tostring(jobs.pending_count()),
        'SMOKE_JOBS_STATUS=' .. tostring(row and row.status or ''),
        'SMOKE_JOBS_HANDLER=' .. tostring(row and row.last_error or ''),
      })
    end)
  end,
  -- The filesystem counterpart of `db_stats`, and non-bootstrapping for the
  -- same reason: bootstrap reads templates and asset metadata, so a probe that
  -- booted would add filesystem work to the number it exists to report.
  fs_stats = function()
    local stats = require 'includes.fs.stats'
    local media = stats.snapshot('media')
    local session = stats.snapshot('session')
    local lines = {
      'SMOKE_FS_OPEN=' .. tostring(media.open),
      'SMOKE_FS_READ=' .. tostring(media.read),
      'SMOKE_FS_WRITE=' .. tostring(media.write),
      'SMOKE_FS_RENAME=' .. tostring(media.rename),
      'SMOKE_FS_REMOVE=' .. tostring(media.remove),
      'SMOKE_FS_BYTES=' .. tostring(media.bytes),
      'SMOKE_FS_SESSION_OPEN=' .. tostring(session.open),
      'SMOKE_FS_SESSION_READ=' .. tostring(session.read),
      'SMOKE_FS_SESSION_WRITE=' .. tostring(session.write),
      'SMOKE_FS_SESSION_REMOVE=' .. tostring(session.remove),
      'SMOKE_FS_SESSION_BYTES=' .. tostring(session.bytes),
    }

    ngx.print(render(lines))
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
  --[[ Who does this request think it is, asked two ways.

    `modules/user` answers from whatever `_SESSION` it is holding; the second
    line reads the jailed environment at call time, which is the table
    `session_start()` built for *this* request. On a correct runtime the two
    agree. They diverge when a module has captured `_SESSION` as a load-time
    local, because `module()` replaces that file's environment and the capture
    then freezes to whichever request happened to load the module.
  ]]
  whoami = function()
    return run_bootstrap(function()
      local user = ophal.modules.user
      local live = env._SESSION or {}

      write(render{
        'SMOKE_LOGGED_IN=' .. tostring(user.is_logged_in() and true or false),
        'SMOKE_MODULE_USER_ID=' .. tostring(user.current().id or ''),
        'SMOKE_SESSION_USER_ID=' .. tostring(live.user_id or ''),
      })
    end)
  end,
  --[[ Does request state survive a yield?

    One worker runs one Lua VM and one coroutine per request, so every global
    and every file upvalue is shared by whatever requests are in flight at the
    same time. Ophal keeps its request state there -- `_GET`, `_SESSION`,
    `ophal.session`, `ophal.cookies`, `base` -- and `ophal_request_reset()`
    rewrites all of it at the start of each request. Nothing goes wrong while a
    request runs start to finish without ever yielding, which is what a
    synchronous database driver buys.

    This scenario spends `delay` seconds inside `ngx.sleep`, which yields, and
    reads the same two values either side of it. A second client sent during
    that sleep runs its own reset in between. The values are `?tag=` and the
    session id, because those are the two the caller controls: one comes from
    the query string and one from the cookie jar.

    A driver that yields on every query makes this the ordinary case rather
    than a race, which is why it is proven here before pgmoon rather than
    after.
  ]]
  interleave = function()
    return run_bootstrap(function()
      local delay = tonumber(query_arg('delay') or '') or 0
      local tag = tostring(query_arg('tag') or '')

      local function snapshot()
        return tostring((env._GET or {}).tag or ''),
          tostring((ophal.session or {}).id or '')
      end

      --[[ A lazy session has no id until something writes into it.

        Writing here is not a workaround for that: it makes this scenario a test
        of *materialization* under interleaving, which is the case that matters
        most now. A session can come into existence in the middle of a request,
        so the id, the cookie and the file are all decided at a point where two
        requests may be in flight -- and `session_materialize()` reaches the
        session through `ophal.session`, which is request state.
      ]]
      _SESSION.tag = tag

      local get_before, session_before = snapshot()

      -- Page state and the per-request accumulators, marked with this
      -- request's own tag. `ophal.title` covers the `ophal` half of the split
      -- and `add_head`/`add_js` cover the closures in `includes/common.lua`,
      -- which fill across a whole request and so span any yield in it.
      ophal.title = tag
      add_head('<!-- interleave:' .. tag .. ' -->')
      add_js{type = 'inline', ('/* interleave:%s */'):format(tag)}

      ngx.update_time()
      local started = ngx.now()

      if delay > 0 then
        ngx.sleep(delay)
      end

      local get_after, session_after = snapshot()

      ngx.update_time()
      local ended = ngx.now()

      write(render{
        -- The timestamps are what stop this from passing vacuously. Two
        -- requests that never overlapped cannot contaminate each other, so the
        -- caller has to be able to prove the second one ran inside the first
        -- one's sleep rather than after it.
        ('SMOKE_START=%.3f'):format(started),
        ('SMOKE_END=%.3f'):format(ended),
        -- Read straight from nginx, so it is this request's own tag whatever
        -- happened to the jailed environment while the coroutine was parked.
        'SMOKE_TAG=' .. tag,
        'SMOKE_GET_BEFORE=' .. get_before,
        'SMOKE_GET_AFTER=' .. get_after,
        'SMOKE_SESSION_BEFORE=' .. session_before,
        'SMOKE_SESSION_AFTER=' .. session_after,
        'SMOKE_SESSION_TAG_AFTER=' .. tostring((env._SESSION or {}).tag or ''),
        'SMOKE_TITLE_AFTER=' .. tostring(ophal.title or ''),
        'SMOKE_HEAD_AFTER=' .. tostring(get_head() or ''):gsub('%s+', ' '),
        'SMOKE_JS_AFTER=' .. tostring((get_js() or {}).header or ''):gsub('%s+', ' '),
      })
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
        'SMOKE_MERGE_ID=' .. tostring(output and output.id or ''),
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
