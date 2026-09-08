-- Unit tests for the deferred file type inspection in modules/file.
--
-- The smoke suite proves the job is enqueued by finalize, registered at load
-- time, and taken by the drain. What it cannot prove is the identification
-- itself: libmagic is an optional binding and is not present in this
-- workspace, so `seawolf.fs.finfo` is nil there and the handler completes
-- without writing anything. That is the honest state of the workspace, not a
-- reason to leave the feature untested, so the binding is stubbed here.

do
  local root = io.popen('pwd'):read('*l')
  local vendor_root = root .. '/tests/smoke/vendor'
  local vendor_share = vendor_root .. '/unpack/usr/share/lua/5.1'

  package.path = table.concat({
    root .. '/?.lua',
    root .. '/?/init.lua',
    vendor_root .. '/?.lua',
    vendor_root .. '/?/init.lua',
    vendor_share .. '/?.lua',
    vendor_share .. '/?/init.lua',
    package.path,
  }, ';')
end

local db_fake = require 'tests.unit.db_fake'

local pass_count, fail_count = 0, 0

local function assert_eq(label, got, expected)
  if got == expected then
    pass_count = pass_count + 1
    io.write(('  ok %s\n'):format(label))
  else
    fail_count = fail_count + 1
    io.write(('  FAIL %s: expected %s, got %s\n'):format(
      label, tostring(expected), tostring(got)))
  end
end

local function result_of(rows)
  local index = 0

  return {
    fetch = function()
      index = index + 1
      return rows[index]
    end,
  }
end

--[[ Load the file module against a controllable world.

  `finfo` is captured as a local when the module loads, so the stub has to be in
  place on `seawolf.fs` before `dofile` and the module has to be reloaded to
  change it. That is the same load-time capture the rest of this file is about;
  here it is a constraint on the test rather than a bug.
]]
local function load_file_module(state)
  -- The stubs go into `package.loaded`, not onto the seawolf table. The module
  -- calls `__build('fs', 'behaviour', 'variable')` on its own first line, and
  -- `__build` requires each component and overwrites whatever was there -- so
  -- anything assigned to `seawolf.fs` beforehand is gone by the time the module
  -- captures `finfo` from it. Seeding `package.loaded` is what makes the
  -- require return these instead.
  --
  -- Only the members the module touches are provided. `__build` is also worth
  -- knowing about for a different reason: when a component fails to load it
  -- stores the *error string* under that name rather than leaving it nil, so a
  -- missing C module shows up later as a string being indexed as a table.
  package.loaded['seawolf.fs'] = {
    is_dir = function() return true end,
    is_file = function() return false end,
    finfo = state.finfo,
  }
  package.loaded['seawolf.behaviour'] = {temp_dir = function() return '/tmp' end}
  package.loaded['seawolf.variable'] = {
    empty = function(v)
      return v == nil or v == '' or v == false or
        (type(v) == 'table' and next(v) == nil)
    end,
  }

  _G.settings = {file = {filedb_storage = true}, site = {files_path = '/tmp/files'}}
  _G.ophal = {modules = {}}
  _G.theme = {}
  _G.header = function() end
  _G.add_js = function() end
  _G.render_attributes = function() return '' end
  _G.format_size = function() return '' end
  _G.format_date = function() return '' end
  _G.csrf_validate_request = function() return true end
  _G.csrf_denied = function() end
  _G.safe_path_segment = function() return true end
  _G.unsafe_path_denied = function() end
  _G.module_invoke_all = function() end

  _G.env = {
    _GET = {},
  }
  db_fake.install({
    sql = function(sql, ...)
      local args = {...}

      state.queries[#state.queries + 1] = {sql = sql, args = args}

      if sql:match('^SELECT %* FROM file WHERE') then
        return result_of{state.row}
      end

      if sql:match('^UPDATE file SET') then
        state.updated = {
          filename = args[2],
          filepath = args[3],
          filemime = args[4],
          id = args[8],
        }
        return result_of{}
      end

      return result_of{}
    end,
  }, _G.env, _G)

  -- `includes/jobs.lua` keeps one registry per process, so a handler from an
  -- earlier block would otherwise still be standing.
  local jobs = require 'includes.jobs'
  jobs.registry_clear()

  -- `module()` only builds the `ophal.modules.file` global chain when it does
  -- not already have the module in `package.loaded`. Without this the second
  -- load leaves `ophal.modules.file` nil, because `_G.ophal` above is a fresh
  -- table and nothing reattaches to it.
  package.loaded['ophal.modules.file'] = nil

  dofile('modules/file/init.lua')
  ophal.modules.file.init()

  return jobs.handler('file_post_process'), jobs
end

io.write '\n-- deferred file type inspection --\n'

-- The feature, with libmagic present.
do
  -- Declared before it is filled in: the stub below closes over `state`, and
  -- inside a `local state = {...}` initializer the name is not a local yet.
  local state = {
    queries = {},
    row = {id = 7, filename = 'report.pdf', filepath = '/tmp/files/report.pdf'},
  }

  state.finfo = {
    MIME_TYPE = 1,
    NO_CHECK_COMPRESS = 2,
    open = function()
      return {
        load = function() return 0 end,
        file = function(_, path)
          state.inspected = path
          return 'application/pdf'
        end,
      }
    end,
  }

  local handler = load_file_module(state)

  assert_eq('post_process_registered', type(handler), 'function')
  assert_eq('post_process_completes', handler{id = 7}, true)
  -- It reads the stored file, not the name or anything the request supplied.
  assert_eq('post_process_inspects_the_stored_file', state.inspected, '/tmp/files/report.pdf')
  assert_eq('post_process_writes_the_mime', state.updated and state.updated.filemime, 'application/pdf')
  assert_eq('post_process_updates_that_row', state.updated and state.updated.id, 7)
end

-- No libmagic. A settled answer, not a retry: `run_pending()` reads a false
-- return as "declined" and requeues with a backoff, so returning false here
-- would burn `max_attempts` on every upload for a binding the host does not
-- have, and leave a failed row behind for each one.
do
  local state = {
    queries = {},
    row = {id = 7, filename = 'report.pdf', filepath = '/tmp/files/report.pdf'},
    finfo = nil,
  }

  local handler = load_file_module(state)

  assert_eq('post_process_without_libmagic_completes', handler{id = 7}, true)
  assert_eq('post_process_without_libmagic_writes_nothing', state.updated, nil)
end

-- Deleted between finalize and the drain. Also settled, and for the same
-- reason: there is nothing a later attempt would find.
do
  local state = {queries = {}, row = nil, finfo = {}}
  local handler = load_file_module(state)

  assert_eq('post_process_missing_file_completes', handler{id = 7}, true)
  assert_eq('post_process_missing_file_writes_nothing', state.updated, nil)
end

-- A row with no path is the same case. `load()` returns a table either way, so
-- emptiness is not the only thing worth checking.
do
  local state = {
    queries = {},
    row = {id = 7, filename = 'report.pdf'},
    finfo = {},
  }

  local handler = load_file_module(state)

  assert_eq('post_process_pathless_row_completes', handler{id = 7}, true)
  assert_eq('post_process_pathless_row_writes_nothing', state.updated, nil)
end

-- A payload with no id at all, which is what a hand-written or truncated job
-- row looks like. It must not raise inside the drain.
do
  local state = {queries = {}, row = nil, finfo = {}}
  local handler = load_file_module(state)

  assert_eq('post_process_no_payload_completes', handler{}, true)
  assert_eq('post_process_nil_payload_completes', handler(nil), true)
end

-- libmagic present but unable to load its database. That is a real failure and
-- the job should come back, so this is the one case that must not report
-- success.
do
  local state = {
    queries = {},
    row = {id = 7, filename = 'report.pdf', filepath = '/tmp/files/report.pdf'},
    finfo = {
      MIME_TYPE = 1,
      NO_CHECK_COMPRESS = 2,
      open = function()
        return {
          load = function() return 1 end,
          error = function() return 'magic database missing' end,
        }
      end,
    },
  }

  local handler = load_file_module(state)
  local ok, err = handler{id = 7}

  assert_eq('post_process_reports_magic_failure', ok, nil)
  assert_eq('post_process_returns_the_error', err, 'magic database missing')
  assert_eq('post_process_magic_failure_writes_nothing', state.updated, nil)
end

io.write(('\n%d passed, %d failed\n'):format(pass_count, fail_count))

if fail_count > 0 then
  os.exit(1)
end
