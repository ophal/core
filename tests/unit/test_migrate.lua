-- Unit tests for the Ophal migration registry and runner.

do
  local root = io.popen('pwd'):read('*l')
  local vendor_root = root .. '/tests/smoke/vendor'
  local vendor_share = vendor_root .. '/unpack/usr/share/lua/5.1'
  local vendor_lib = io.popen("find '" .. vendor_root .. "/unpack/usr/lib' -path '*/lua/5.1' -type d 2>/dev/null | sed -n '1p'"):read('*l')

  package.path = table.concat({
    root .. '/?.lua',
    root .. '/?/init.lua',
    vendor_root .. '/?.lua',
    vendor_root .. '/?/init.lua',
    vendor_share .. '/?.lua',
    vendor_share .. '/?/init.lua',
    package.path,
  }, ';')

  if vendor_lib and vendor_lib ~= '' then
    package.cpath = vendor_lib .. '/?.so;' .. package.cpath
  end
end

local migrate = dofile('includes/migrate.lua')

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

local function assert_match(label, got, pattern)
  if tostring(got):match(pattern) then
    pass_count = pass_count + 1
    io.write(('  ok %s\n'):format(label))
  else
    fail_count = fail_count + 1
    io.write(('  FAIL %s: %q did not match %q\n'):format(
      label, tostring(got), pattern))
  end
end

local function rows_from(items)
  return {
    rows = function()
      local index = 0
      return function()
        index = index + 1
        return items[index]
      end
    end,
  }
end

local function new_db_state()
  return {
    ensured = false,
    applied = {},
    queries = {},
  }
end

local function db_query_stub(state)
  return function(query, ...)
    local args = {...}
    state.queries[#state.queries + 1] = {query = query, args = args}

    if query:match('^CREATE TABLE IF NOT EXISTS ophal_migrations') then
      state.ensured = true
      return {query = query}
    elseif query == 'SELECT id FROM ophal_migrations ORDER BY id' then
      local rows = {}
      for _, id in ipairs(state.applied) do
        rows[#rows + 1] = {id = id}
      end
      return rows_from(rows)
    elseif query == 'INSERT INTO ophal_migrations(id, module, applied_at) VALUES(?, ?, ?)' then
      state.applied[#state.applied + 1] = args[1]
      return {query = query}
    end

    return {query = query, args = args}
  end
end

io.write '\n-- migration collection --\n'

do
  local migrations = assert(migrate.collect({
    module_names = {'system', 'comment'},
    core_migrations = {
      {
        id = '001_core',
        up = function() end,
      },
    },
    module_migrations = {
      comment = {
        {
          id = '001_comment',
          up = function() end,
        },
      },
    },
  }))

  assert_eq('collect_count', #migrations, 2)
  assert_eq('collect_core_id', migrations[1].id, 'core:001_core')
  assert_eq('collect_comment_id', migrations[2].id, 'comment:001_comment')
end

do
  local result, err = migrate.collect({
    module_names = {'system'},
    core_migrations = {
      {
        id = '001_dup',
        up = function() end,
      },
    },
    module_migrations = {
      system = {
        {
          id = 'core:001_dup',
          up = function() end,
        },
      },
    },
  })

  assert_eq('duplicate_collect_nil', result, nil)
  assert_match('duplicate_collect_error', err, 'duplicate migration id')
end

io.write '\n-- migration status --\n'

do
  local state = new_db_state()
  state.applied = {'core:001_core'}

  local status = assert(migrate.status({
    driver = 'sqlite3',
    db_query = db_query_stub(state),
    module_names = {'system', 'comment'},
    core_migrations = {
      {
        id = '001_core',
        up = function() end,
      },
    },
    module_migrations = {
      comment = {
        {
          id = '001_comment',
          up = function() end,
        },
      },
    },
  }))

  assert_eq('status_store_ensured', state.ensured, true)
  assert_eq('status_applied_count', status.applied_count, 1)
  assert_eq('status_pending_count', status.pending_count, 1)
  assert_eq('status_pending_id', status.pending[1].id, 'comment:001_comment')
end

io.write '\n-- migration apply --\n'

do
  local state = new_db_state()
  local applied_steps = {}
  local cache_cleared = false

  local result = assert(migrate.apply({
    driver = 'sqlite3',
    db_query = db_query_stub(state),
    cache_clear_all = function()
      cache_cleared = true
    end,
    module_names = {'system', 'comment'},
    core_migrations = {
      {
        id = '001_core',
        up = function(ctx)
          applied_steps[#applied_steps + 1] = ctx.id
          return ctx.db_query('SELECT 1')
        end,
      },
    },
    module_migrations = {
      comment = {
        {
          id = '001_comment',
          up = function(ctx)
            applied_steps[#applied_steps + 1] = ctx.id
            return ctx.db_query('SELECT 2')
          end,
        },
      },
    },
  }))

  assert_eq('apply_applied_count', result.applied_count, 2)
  assert_eq('apply_first_step', applied_steps[1], 'core:001_core')
  assert_eq('apply_second_step', applied_steps[2], 'comment:001_comment')
  assert_eq('apply_record_first', state.applied[1], 'core:001_core')
  assert_eq('apply_record_second', state.applied[2], 'comment:001_comment')
  assert_eq('apply_cache_clear', cache_cleared, true)
end

do
  local state = new_db_state()
  state.applied = {'core:001_core'}
  local cache_cleared = false

  local result = assert(migrate.apply({
    driver = 'sqlite3',
    db_query = db_query_stub(state),
    cache_clear_all = function()
      cache_cleared = true
    end,
    module_names = {'system'},
    core_migrations = {
      {
        id = '001_core',
        up = function()
          error('should not run')
        end,
      },
    },
  }))

  assert_eq('apply_none_applied_count', result.applied_count, 0)
  assert_eq('apply_none_cache_clear', cache_cleared, false)
end

do
  local state = new_db_state()
  local result, err = migrate.apply({
    driver = 'sqlite3',
    db_query = db_query_stub(state),
    module_names = {'system'},
    core_migrations = {
      {
        id = '001_fail',
        up = function()
          return nil, 'boom'
        end,
      },
    },
  })

  assert_eq('apply_failure_result_nil', result, nil)
  assert_eq('apply_failure_no_record', #state.applied, 0)
  assert_match('apply_failure_error', err, 'boom')
end

io.write(('\n%d passed, %d failed\n'):format(pass_count, fail_count))
if fail_count > 0 then
  os.exit(1)
end
