--[[ Can anything reach SQL as syntax rather than as data?

  The driver contract proves a row can be read. This proves a hostile value
  cannot become part of the statement that reads it. Same three backends, same
  layer, but every input here is chosen to break out: quotes, comment
  introducers, statement terminators, a NUL, and a multibyte sequence whose
  trailing byte is a backslash in the single-byte reading.

  The canary is the mechanism. Every probe runs against a table holding one
  known row; if a value or an identifier ever reaches the server as syntax, the
  canary is dropped or emptied and the assertion after it says so. A probe that
  merely raises is a pass -- being refused is the correct outcome. What is not
  a pass is being accepted and executed.

    bash tests/bench/setup_backends.sh all   # once
    bash tests/bench/run_injection_probe.sh
]]

package.path = './?.lua;./?/init.lua;' .. package.path

settings = {
  db = {
    default = {
      driver = 'pgmoon', database = 'ophal_bench',
      username = 'ophal', password = 'ophal',
      host = '127.0.0.1', port = 15432,
    },
    mysql = {
      driver = 'resty-mysql', database = 'ophal_bench',
      username = 'ophal', password = 'ophal',
      host = '127.0.0.1', port = 13306,
    },
    sqlite = {
      driver = 'SQLite3',
      database = os.getenv('OPHAL_BENCH_SQLITE') or '/tmp/ophal_injection.sqlite',
    },
  },
  performance = {query_stats = false},
}

local registry = require 'includes.database.registry'
local connection = require 'includes.database.connection'
local request_state = require 'includes.request_state'
require 'includes.database.statements'

local passed, failed = 0, 0

local function ok(name)
  passed = passed + 1
  io.write(('  ok %s\n'):format(name))
end

local function bad(name, detail)
  failed = failed + 1
  io.write(('  FAIL %s: %s\n'):format(name, detail))
end

local function assert_eq(name, actual, expected)
  if actual == expected then ok(name)
  else bad(name, ('expected %s, got %s'):format(tostring(expected), tostring(actual))) end
end

--[[ The payloads.

  Each is a complete break-out attempt for at least one of the three dialects.
  `NUL` is here because a C binding that takes a length from strlen truncates
  there while Lua does not, so a payload after it would be invisible to any
  check written in Lua. `GBK` is the multibyte case: 0x81 0x5C is one character
  in GBK and `backslash` in a single-byte reading, so a backslash-escaping
  escaper that does not know the connection charset can be walked out of.
]]
local PAYLOADS = {
  quote           = "' OR '1'='1",
  terminator      = "'; DROP TABLE ophal_canary; --",
  comment         = "'/*",
  backslash       = "\\' OR 1=1 --",
  double_quote    = '" OR "1"="1',
  nul             = "a\0' OR '1'='1",
  gbk             = "\xbf\x27 OR 1=1 --",
  newline         = "'\n OR 1=1 --",
  dollar_quoted   = "$$ OR 1=1 --",
  backtick        = "` OR 1=1 --",
}

-- Identifiers are a separate surface: these are attempts to become a column or
-- a table name, not a value.
local IDENT_PAYLOADS = {
  ident_or        = 'id FROM ophal_canary WHERE 1=1 --',
  ident_semicolon = 'id; DROP TABLE ophal_canary',
  ident_quoted    = 'id" FROM ophal_canary WHERE "1"="1',
  ident_star      = '*',
  ident_space     = 'id, title',
  ident_comment   = 'id--',
  ident_paren     = 'id) OR (1=1',
  ident_empty     = '',
}

local SCHEMA = {
  lsqlite3 = {
    'DROP TABLE IF EXISTS ophal_canary',
    [[CREATE TABLE ophal_canary(
      id INTEGER PRIMARY KEY AUTOINCREMENT, title VARCHAR(255), note VARCHAR(255))]],
  },
  pgmoon = {
    'DROP TABLE IF EXISTS ophal_canary',
    [[CREATE TABLE ophal_canary(
      id SERIAL PRIMARY KEY, title VARCHAR(255), note VARCHAR(255))]],
  },
  ['resty-mysql'] = {
    'DROP TABLE IF EXISTS ophal_canary',
    [[CREATE TABLE ophal_canary(
      id BIGINT AUTO_INCREMENT PRIMARY KEY, title VARCHAR(255), note VARCHAR(255))]],
  },
}

registry.define('canary.insert', {
  sql = 'INSERT INTO ophal_canary (title, note) VALUES (?, ?)',
  tables = {'ophal_canary'},
})
registry.define('canary.by_title', {
  sql = 'SELECT id, title, note FROM ophal_canary WHERE title = ?',
  tables = {'ophal_canary'},
})
registry.define('canary.count', {
  sql = 'SELECT COUNT(*) AS total FROM ophal_canary',
  tables = {'ophal_canary'},
})
-- The identifier surface, shaped exactly like `user.load_by_field`: the column
-- is a compile key resolved through the connection's own schema.
registry.define('canary.by_field', {
  sql = 'SELECT id, title FROM ophal_canary WHERE {field} = ?',
  idents = {field = function(value, conn) return conn:field('ophal_canary', value) end},
  order = {'field'},
  tables = {'ophal_canary'},
})
-- The single-guard identifier surface: `registry.trusted` asserts the value is
-- written in a declaration rather than arriving from data, and validates
-- nothing, so all that stands here is the registry's own shape check. What
-- relies on it today is `core.last_insert_id`, whose table and column every
-- caller names itself. `entity.delete` used to be here too and no longer is:
-- its value comes from the URL, so it resolves through `connection:table()`.
--
-- The assertions below are what say the remaining single guard actually holds.
registry.define('canary.bare_ident', {
  sql = 'SELECT id FROM ophal_canary WHERE {field:bare} = ?',
  idents = {field = registry.trusted},
  order = {'field'},
  tables = {'ophal_canary'},
})

local function canary_intact(db)
  local okc, res = pcall(function()
    return tonumber((db:run('canary.count'):fetch(true) or {}).total)
  end)
  return okc and res == 1
end

local function fresh(name)
  request_state.reset()
  return connection.open(name or 'default')
end

--[[ Each payload gets its own connection.

  A statement the server refuses leaves the handle mid-protocol -- pgmoon says
  "connection is busy" on the next call -- and the layer's own answer to that is
  to close rather than pool it, which is `release(false)`. So reusing one
  connection across probes measures the harness, not the layer. This is also the
  honest shape: in production each of these would be one request.
]]
local function with_connection(name, fn)
  local db = fresh(name)
  local okc, err = pcall(fn, db)
  pcall(db.release, db, okc)
  return okc, err
end

local function setup(name)
  local db = fresh(name)
  local driver = db:driver()
  for _, sql in ipairs(SCHEMA[driver]) do db:execute(sql) end
  db:run('canary.insert', 'canary', 'untouched')
  db:release(true)
  return driver
end

local function count(name)
  local total
  with_connection(name, function(db)
    total = tonumber((db:run('canary.count'):fetch(true) or {}).total)
  end)
  return total
end

local function probe(label, name)
  local driver = setup(name)

  io.write(('\n-- %s (%s) --\n'):format(label, driver))

  -- 1. Values. Accepted-and-stored or refused are both correct; what must never
  -- happen is the value changing the shape of the statement.
  for pname, payload in pairs(PAYLOADS) do
    local matched
    local sent, err = with_connection(name, function(db)
      db:run('canary.insert', payload, 'v')
      local n = 0
      for _ in db:run('canary.by_title', payload):rows(true) do n = n + 1 end
      matched = n
    end)

    if sent and matched == 1 then
      ok(('%s_value_%s_is_data'):format(driver, pname))
    elseif not sent then
      -- Refused. Report by whom, because "the server rejected it" and "the
      -- layer rejected it" are different guarantees.
      ok(('%s_value_%s_refused (%s)'):format(driver, pname,
        tostring(err):gsub('%s+', ' '):sub(1, 60)))
    else
      bad(('%s_value_%s'):format(driver, pname),
        ('did not read back as one row (matched=%s)'):format(tostring(matched)))
    end

    with_connection(name, function(db)
      db:execute('DELETE FROM ophal_canary WHERE note = ?', 'v')
    end)
  end

  assert_eq(('%s_canary_survives_values'):format(driver), count(name), 1)

  -- 2. Identifiers through the schema whitelist, and 3. through the bare path,
  -- which has only the registry's shape check.
  for _, spec in ipairs{{'', 'canary.by_field'}, {'bare_', 'canary.bare_ident'}} do
    for pname, payload in pairs(IDENT_PAYLOADS) do
      local sent = with_connection(name, function(db)
        return db:with(spec[2], payload):run(1):fetch(true)
      end)
      assert_eq(('%s_%s%s_refused'):format(driver, spec[1], pname), sent, false)
    end
  end

  assert_eq(('%s_canary_survives_identifiers'):format(driver), count(name), 1)

  -- 4. Second order: stored as data, then read back and used as an identifier.
  local stored
  with_connection(name, function(db)
    db:run('canary.insert', IDENT_PAYLOADS.ident_or, 'second-order')
    stored = db:run('canary.by_title', IDENT_PAYLOADS.ident_or):fetch(true)
  end)
  assert_eq(('%s_second_order_stored'):format(driver),
    (stored or {}).title, IDENT_PAYLOADS.ident_or)
  local reused = with_connection(name, function(db)
    return db:with('canary.by_field', (stored or {}).title):run(1):fetch(true)
  end)
  assert_eq(('%s_second_order_refused'):format(driver), reused, false)
  with_connection(name, function(db)
    db:execute('DELETE FROM ophal_canary WHERE note = ?', 'second-order')
  end)

  -- 5. Ad-hoc SQL must bind, not concatenate.
  local adhoc_n
  local adhoc_ok = with_connection(name, function(db)
    db:run('canary.insert', PAYLOADS.terminator, 'adhoc')
    local n = 0
    for _ in db:execute('SELECT id FROM ophal_canary WHERE title = ?',
        PAYLOADS.terminator):rows(true) do n = n + 1 end
    adhoc_n = n
  end)
  assert_eq(('%s_execute_binds_its_values'):format(driver), adhoc_ok and adhoc_n, 1)
  with_connection(name, function(db)
    db:execute('DELETE FROM ophal_canary WHERE note = ?', 'adhoc')
  end)

  -- 6. The shape `modules/user` uses for its permission read: an IN list whose
  -- width is not known until it runs, built by concatenating its values into
  -- the statement instead of binding them. The ids there come from `user_role`
  -- and never from a request, so this is not reachable today -- but it is the
  -- only value interpolation left in the codebase, and this is what it would
  -- cost if a write path for roles ever landed. Binding the same list is the
  -- assertion beside it: the layer already supports it, at any width.
  local ids = {'1', '2'}
  local hostile = {'1', "1') OR ('1'='1"}

  local function in_list_concat(db, values)
    local quoted = {}
    for i, v in ipairs(values) do quoted[i] = tostring(v) end
    local n = 0
    for _ in db:execute(([[
SELECT id FROM ophal_canary WHERE title = 'nothing' OR note IN ('%s')]])
        :format(table.concat(quoted, "', '"))):rows(true) do n = n + 1 end
    return n
  end

  local function in_list_bound(db, values)
    local marks = {}
    for i = 1, #values do marks[i] = '?' end
    local n = 0
    for _ in db:execute(
        ('SELECT id FROM ophal_canary WHERE title = \'nothing\' OR note IN (%s)')
          :format(table.concat(marks, ', ')),
        unpack(values)):rows(true) do n = n + 1 end
    return n
  end

  local benign, hostile_n
  with_connection(name, function(db) benign = in_list_concat(db, ids) end)
  assert_eq(('%s_in_list_concat_benign_matches_nothing'):format(driver), benign, 0)

  with_connection(name, function(db) hostile_n = in_list_concat(db, hostile) end)
  -- The canary row is returned by a WHERE clause that was written to match
  -- nothing. That is the injection, and it is why this pattern has to go.
  assert_eq(('%s_in_list_concat_IS_INJECTABLE'):format(driver), hostile_n, 1)

  local bound_benign, bound_hostile
  with_connection(name, function(db) bound_benign = in_list_bound(db, ids) end)
  with_connection(name, function(db) bound_hostile = in_list_bound(db, hostile) end)
  -- Matching nothing or being refused outright are both correct; returning the
  -- canary is not.
  assert_eq(('%s_in_list_bound_benign_matches_nothing'):format(driver), bound_benign, 0)
  assert_eq(('%s_in_list_bound_resists'):format(driver), bound_hostile, 0)

  assert_eq(('%s_canary_survives_everything'):format(driver), count(name), 1)
end

io.write('=== injection probe ===\n')
probe('PostgreSQL', nil)
probe('MySQL', 'mysql')
probe('SQLite', 'sqlite')

io.write(('\n%d passed, %d failed\n'):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
