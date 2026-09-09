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

io.write '\n-- migration db handle access --\n'

do
  local state = new_db_state()
  local seen_handle
  local saved_settings = settings
  local saved_db_connection = db_connection
  local saved_dbh = dbh

  settings = {
    db = {
      default = 'primary',
      primary = {
        driver = 'sqlite3',
      },
    },
  }
  dbh = nil
  db_connection = function(id)
    return {id = id}
  end

  local result = assert(migrate.apply({
    db_query = db_query_stub(state),
    settings = settings,
    module_names = {'system'},
    core_migrations = {
      {
        id = '001_handle',
        up = function(ctx)
          seen_handle = ctx.db_handle
        end,
      },
    },
  }))

  assert_eq('apply_db_handle_count', result.applied_count, 1)
  assert_eq('apply_db_handle_id', seen_handle.id, 'primary')

  settings = saved_settings
  db_connection = saved_db_connection
  dbh = saved_dbh
end

--[[ The same, with `default` holding the connection table.

  This is the documented shape -- what `examples/vault.lua` shows and what
  `includes/install.lua` generates -- and it used to answer nil, because
  `db_handle()` read `settings.db.default` as the *name* of another entry and
  so indexed the handle table with a table. `driver_name()` beside it had been
  taught both shapes and this had not; no test asked the two to agree, and each
  had its own passing one.
]]
do
  local state = new_db_state()
  local seen_handle
  local saved_settings = settings
  local saved_db_connection = db_connection

  settings = {
    db = {
      default = {
        driver = 'sqlite3',
        database = 'site.sqlite',
      },
    },
  }
  db_connection = function(id)
    return {id = id}
  end

  local result = assert(migrate.apply({
    db_query = db_query_stub(state),
    settings = settings,
    module_names = {'system'},
    core_migrations = {
      {
        id = '001_handle',
        up = function(ctx)
          seen_handle = ctx.db_handle
        end,
      },
    },
  }))

  assert_eq('apply_db_handle_documented_count', result.applied_count, 1)
  assert_eq('apply_db_handle_documented_id', seen_handle and seen_handle.id,
    'default')

  settings = saved_settings
  db_connection = saved_db_connection
end

io.write '\n-- core migration registry --\n'

-- Every registered migration has to be runnable on both drivers. This is not a
-- formality: `tag_listing_index_sql` was once declared inside another function
-- and so was nil at the point the registry referenced it, which made
-- `004_tag_listing_index` fail for every site that ever ran it while the three
-- migrations beside it kept passing.
do
  local registry = dofile('includes/migrations.lua')

  assert_eq('core_registry_count', #registry, 5)

  for _, driver in ipairs({'sqlite3', 'postgresql', 'mysql'}) do
    for _, migration in ipairs(registry) do
      local statements = {}
      local ok, err = pcall(migration.up, {
        driver = driver,
        db_query = function(statement)
          statements[#statements + 1] = statement
          return true
        end,
      })

      assert_eq(('core_migration_runs_%s_%s'):format(driver, migration.id), ok, true)
      if not ok then
        io.write(('    %s\n'):format(tostring(err)))
      end
      assert_eq(
        ('core_migration_emits_sql_%s_%s'):format(driver, migration.id),
        #statements > 0,
        true
      )
    end
  end
end

io.write '\n-- the ledger is per dialect --\n'

--[[ `ophal_migrations` has its own DDL per dialect, and the MySQL one landed in
  stage 8.7 with nothing in the unit suite naming it -- every `apply` and
  `status` test above runs on sqlite3. It executed for real in the MySQL smoke
  profile, which is why the gap did not show, but "it ran once" is not the same
  claim as "it emits MySQL".

  So each dialect is checked against the *other* dialects' spellings, the way
  `test_jobs.lua` checks the five migrations: `UNSIGNED BIG INT` is SQLite's
  alone and `character varying` is PostgreSQL's alone, so a branch that fell
  through to another dialect fails by name rather than passing because it ran.
]]
do
  local ledger = {}

  for _, driver in ipairs({'sqlite3', 'postgresql', 'mysql'}) do
    local state = new_db_state()

    -- Not `assert`: a dialect with no branch answers nil, and a raise here
    -- would take the other dialects' assertions with it instead of naming the
    -- one that is missing.
    migrate.status({
      driver = driver,
      db_query = db_query_stub(state),
      module_names = {},
      core_migrations = {},
      module_migrations = {},
    })

    ledger[driver] = state.queries[1] and state.queries[1].query or ''
    assert_eq(('ledger_ensured_%s'):format(driver), state.ensured, true)
  end

  assert_match('ledger_sqlite3_spelling', ledger.sqlite3, 'UNSIGNED BIG INT')
  assert_match('ledger_postgresql_spelling', ledger.postgresql, 'character varying')
  assert_match('ledger_mysql_spelling', ledger.mysql, 'VARCHAR%(255%) NOT NULL PRIMARY KEY')
  assert_eq('ledger_mysql_is_not_sqlite3',
    ledger.mysql:match('UNSIGNED BIG INT'), nil)
  assert_eq('ledger_mysql_is_not_postgresql',
    ledger.mysql:match('character varying'), nil)
end

do
  local state = new_db_state()
  local result, err = migrate.status({
    driver = 'oracle',
    db_query = db_query_stub(state),
    module_names = {},
    core_migrations = {},
    module_migrations = {},
  })

  assert_eq('ledger_unsupported_driver_refused', result, nil)
  assert_match('ledger_unsupported_driver_named', err, 'oracle')
end

io.write '\n-- migration driver resolution --\n'

-- `settings.db.default` holds the connection table in the documented
-- configuration, and that is the shape `db_connect()` reads. Resolving the
-- driver from it used to index `settings.db` with that table and fail, so
-- migrations could not run against a settings file written the documented way.
do
  local state = new_db_state()
  local seen_driver

  -- pcall rather than assert: resolving this shape used to raise inside the
  -- error path itself, and a crash here would take the rest of the file with it
  -- instead of naming what broke.
  local ok, result = pcall(migrate.apply, {
    db_query = db_query_stub(state),
    settings = {
      db = {
        default = {
          driver = 'SQLite3',
          database = 'ophal.sqlite3',
        },
      },
    },
    module_names = {},
    core_migrations = {
      {
        id = '001_driver',
        up = function(ctx)
          seen_driver = ctx.driver
        end,
      },
    },
  })

  assert_eq('apply_documented_db_shape_ok', ok, true)
  assert_eq('apply_documented_db_shape', ok and type(result) == 'table' and result.applied_count, 1)
  assert_eq('apply_documented_db_driver', seen_driver, 'sqlite3')
end

-- The indirect shape, where `default` names another key, still resolves.
do
  local state = new_db_state()
  local seen_driver

  local ok = pcall(migrate.apply, {
    db_query = db_query_stub(state),
    settings = {
      db = {
        default = 'primary',
        primary = {driver = 'PostgreSQL'},
      },
    },
    module_names = {},
    core_migrations = {
      {
        id = '001_driver',
        up = function(ctx)
          seen_driver = ctx.driver
        end,
      },
    },
  })

  assert_eq('apply_indirect_db_shape_ok', ok, true)
  assert_eq('apply_indirect_db_driver', seen_driver, 'postgresql')
end

io.write(('\n%d passed, %d failed\n'):format(pass_count, fail_count))
if fail_count > 0 then
  os.exit(1)
end
