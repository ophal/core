--[[ Statements declared once, compiled once per driver.

  A call site names a statement; it does not carry SQL. The body is written in
  the portable dialect the codebase already uses -- `?` placeholders -- with
  per-dialect overrides where a backend forces one, and it is compiled for the
  active driver on first use: placeholders rendered in that driver's style,
  identifiers substituted and quoted, the tables it touches resolved into the
  bucket `includes/database/stats.lua` counts.

  Compilation is keyed on the *driver*, not on the connection. Two connections
  to two databases through one driver share every compiled statement, which is
  what makes a second database on the same backend cost nothing. Prepared
  handles are the opposite -- those belong to a session, so a driver that has
  them caches them per connection.

  The four functions in `includes/database/sqlite3.lua` and
  `postgresql.lua` -- `limit()`, `last_insert_id()`, `table_schema_sql()`,
  `claim_jobs_sql()` -- are this pattern written informally for four
  statements. This generalizes it; it does not import anything.
]]

local M = {}

local stats = require 'includes.database.stats'

local format, gsub, sub = string.format, string.gsub, string.sub

local statements = {}

-- compiled[driver][name] for a statement with no identifiers, and one nested
-- level per identifier beyond that.
local compiled = {}

local function fail(message, ...)
  error(('database statement: ' .. message):format(...), 0)
end

local function is_identifier(value)
  return type(value) == 'string' and value:match('^[%a_][%w_]*$') ~= nil
end

--[[ Split a body at its bind placeholders.

  Returns the literal pieces and the placeholder count, so `#pieces` is always
  count + 1. A `?` inside a quoted literal is data rather than a placeholder --
  no statement here has one today, and finding out the hard way later is not
  worth the four lines it costs to be right now.
]]
local function split_placeholders(body)
  local pieces, start, quoted = {}, 1, false
  local i, n = 1, #body

  while i <= n do
    local c = sub(body, i, i)

    if quoted then
      if c == "'" then
        -- '' inside a literal is an escaped quote, not the end of one.
        if sub(body, i + 1, i + 1) == "'" then
          i = i + 1
        else
          quoted = false
        end
      end
    elseif c == "'" then
      quoted = true
    elseif c == '?' then
      pieces[#pieces + 1] = sub(body, start, i - 1)
      start = i + 1
    end

    i = i + 1
  end

  if quoted then
    fail('unterminated string literal in: %s', body)
  end

  pieces[#pieces + 1] = sub(body, start)

  return pieces, #pieces - 1
end

local function render(driver, pieces, count)
  local style = driver.placeholder

  if style == 'question' then
    return table.concat(pieces, '?'), nil
  elseif style == 'numbered' then
    local out = {pieces[1]}

    for i = 1, count do
      out[#out + 1] = '$' .. i
      out[#out + 1] = pieces[i + 1]
    end

    return table.concat(out), nil
  elseif style == nil then
    --[[ The driver cannot bind, so the layer builds the SQL -- and how it
      builds it was decided by measuring rather than by taste.

      The first design interleaved escaped values between literal chunks with
      `table.concat`. A format string beat it by 2.7x on one parameter (126 ns
      against 344) and 1.3x on five (988 against 1279), because `string.format`
      sizes and fills one buffer where the chunk path allocates a table, fills
      it, and then concatenates it.

      Chunks are still produced, for the statements with more parameters than
      the dispatch in the driver covers. Nothing in the codebase has that many
      today; the fallback exists so that adding one is not a silent slowdown
      into a path that no longer works.

      A literal `%` has to survive into the output, so it is doubled here --
      `LIKE '%foo%'` is ordinary SQL and would otherwise be read by `format` as
      a conversion.
    ]]
    local escaped = {}

    for i, piece in ipairs(pieces) do
      escaped[i] = (piece:gsub('%%', '%%%%'))
    end

    return nil, pieces, table.concat(escaped, '%s')
  end

  fail('driver %s declares unknown placeholder style %q',
    tostring(driver.name), tostring(style))
end

--[[ Substitute `{ident}` slots.

  An identifier is part of the compile key rather than a runtime parameter, so
  it is validated and quoted here -- once per distinct value per worker --
  rather than concatenated into SQL on every call, which is what
  `'DELETE FROM ' .. entity.type` does today.
]]
local function substitute(text, decl, values, driver, connection)
  return (gsub(text, '{(%w+)(:?%a*)}', function(key, modifier)
    local resolver = decl.idents and decl.idents[key]
    local value = values[key]

    if resolver == nil then
      fail('%s has no identifier named %q', decl.name, key)
    end

    if value == nil then
      fail('%s needs identifier %q', decl.name, key)
    end

    if type(resolver) == 'function' then
      local resolved, err = resolver(value, connection)

      if resolved == nil then
        fail('%s rejected identifier %s=%q: %s',
          decl.name, key, tostring(value), tostring(err or 'not allowed'))
      end

      value = resolved
    end

    if not is_identifier(value) then
      fail('%s identifier %s=%q is not an identifier',
        decl.name, key, tostring(value))
    end

    --[[ `{name}` is an identifier and gets quoted. `{name:bare}` is a name in
      some other position -- PostgreSQL's `CURRVAL('content_id_seq')` builds a
      sequence name inside a *string literal*, where identifier quotes would
      produce `'"content"_"id"_seq'` and no such sequence exists.

      Unquoted is safe here and only here because the value has already been
      held to `^[%a_][%w_]*$` above: a name that matches that cannot carry a
      quote, a comment or a semicolon. The check is the safety property, and the
      quoting is the correctness one.
    ]]
    if modifier == ':bare' then
      return value
    elseif modifier ~= '' then
      fail('%s: unknown identifier modifier %q on %q', decl.name, modifier, key)
    end

    return driver.quote_identifier and driver.quote_identifier(value) or value
  end))
end

--[[ Declare a statement.

    db.define('content.load', {
      sql    = 'SELECT * FROM content WHERE id = ?',
      tables = {'content'},
    })

  `sql` is the portable body. A key named for a dialect -- `sqlite3`,
  `postgresql`, `mysql` -- overrides it there, which is how `claim_jobs_sql()`
  stops being a special case. `tables` names what the statement touches, so
  attribution is a field rather than a parse. `idents` declares `{slot}` names
  with an optional resolver.
]]
function M.define(name, decl)
  if type(name) ~= 'string' or name == '' then
    fail('a statement needs a name')
  end

  if statements[name] ~= nil then
    fail('%s is already defined', name)
  end

  if type(decl) ~= 'table' or type(decl.sql) ~= 'string' then
    fail('%s needs an sql body', name)
  end

  decl.name = name
  statements[name] = decl

  return decl
end

function M.declaration(name)
  return statements[name]
end

function M.defined()
  local names = {}

  for name in pairs(statements) do
    names[#names + 1] = name
  end

  table.sort(names)

  return names
end

-- Only the unit suite needs this; declarations are load-time and immutable.
function M.reset()
  statements, compiled = {}, {}
end

--[[ Dialect fragments that are not worth a whole override.

  `LIMIT` is the one that matters: PostgreSQL spells it `OFFSET ? LIMIT ?` and
  SQLite and MySQL spell it `LIMIT ?, ?`. Without a macro every paginated
  statement would carry a per-dialect copy of itself to vary six characters, and
  a fourth backend would mean editing all of them.

  Both forms take (offset, count) in that order, which is why one parameter
  order serves every dialect and no permutation is needed. That is not luck --
  it is the same fact that lets today's portable `db_limit()` work at all.
]]
local function expand_macros(body, driver)
  return (gsub(body, '{{(%w+)}}', function(macro)
    local value = driver[macro .. '_clause']

    if value == nil then
      fail('driver %s defines no {{%s}}', tostring(driver.name), macro)
    end

    return value
  end))
end

local function build(decl, driver, values, connection)
  local body = decl.sql
  local override = driver.dialect and decl[driver.dialect]
  local tables, pieces, count, sql, chunks, template

  if type(override) == 'table' and type(override.sql) == 'string' then
    body = override.sql
  end

  if body:find('{{', 1, true) then
    body = expand_macros(body, driver)
  end

  if decl.idents then
    body = substitute(body, decl, values, driver, connection)
  end

  pieces, count = split_placeholders(body)
  sql, chunks, template = render(driver, pieces, count)

  tables = {}

  for i, name in ipairs(decl.tables or {}) do
    if decl.idents then
      -- A statement whose table is an identifier attributes to the table it
      -- was actually compiled for, not to the literal `{table}`.
      name = substitute(name, decl, values, {}, connection)
    end

    tables[i] = name:lower()
  end

  return {
    name = decl.name,
    driver = driver.name,
    sql = sql,
    chunks = chunks,
    template = template,
    nparams = count,
    tables = tables,
    -- The bucket a query lands in is a property of the statement, so it is
    -- decided here rather than re-derived by tokenizing SQL on every call.
    bucket = stats.bucket(tables),
  }
end

--[[ The compiled form of `name` for `driver`, cached.

  Identifier values are part of the key. Lookup walks one nested table per
  identifier and allocates nothing.
]]
function M.compile(driver, name, values, connection)
  local decl = statements[name]
  local per_driver = compiled[driver.name]
  local node

  if decl == nil then
    fail('%s is not defined', tostring(name))
  end

  if per_driver == nil then
    per_driver = {}
    compiled[driver.name] = per_driver
  end

  node = per_driver[name]

  if decl.idents == nil then
    if node == nil then
      node = build(decl, driver, nil, connection)
      per_driver[name] = node
    end

    return node
  end

  if node == nil then
    node = {}
    per_driver[name] = node
  end

  -- `order` fixes the walk, so the same identifiers always reach the same leaf.
  for _, key in ipairs(decl.order or fail('%s with idents needs an order', name)) do
    local value = values[key]
    local next_node = node[value]

    if next_node == nil then
      next_node = {}
      node[value] = next_node
    end

    node = next_node
  end

  if node.compiled == nil then
    node.compiled = build(decl, driver, values, connection)
  end

  return node.compiled
end

--[[ Compile a string of SQL that was not declared.

  For migrations, the installer and the CLI, where the text is not known until
  it runs. It goes through the same renderer as a declaration, so a non-binding
  driver gets its template and a numbered one gets its `$n` -- the difference is
  only that nothing is cached and attribution falls back to the tokenizer, which
  is what that parser is for.
]]
function M.compile_text(driver, sql)
  local pieces, count = split_placeholders(sql)
  local rendered, chunks, template = render(driver, pieces, count)
  local tables = stats.tables(sql)

  return {
    name = sql,
    driver = driver.name,
    sql = rendered,
    chunks = chunks,
    template = template,
    nparams = count,
    tables = tables,
    bucket = stats.bucket(tables),
  }
end

return M
