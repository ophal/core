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

local gsub, sub = string.gsub, string.sub

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

--[[ The resolver for an identifier that comes from a declaration, not from data.

  Every `idents` entry is a function, so a declaration cannot quietly have no
  guard at all. Two kinds exist. A schema lookup -- `connection:field()` for a
  column, `connection:table()` for a table -- answers from the live database, so
  the whitelist cannot drift from what is actually there; that is the one to
  reach for whenever the value arrives from data. This is the other kind, and it
  validates nothing beyond the `^[%a_][%w_]*$` shape every identifier gets.

  Validating nothing is the point. It is a claim about *provenance* rather than
  a check: the value is written in Ophal's own source and never reaches the
  layer from a request. `db:with('core.last_insert_id', 'content', 'id')` is the
  honest case -- the framework names that table and that column itself.

  So it is deliberately a named function rather than the `true` that used to sit
  in these slots. `true` and a real resolver read identically at a glance, which
  meant the difference between one guard and two was only discoverable by
  reading all six declarations; this is greppable, and the grep is the audit.

  Do not reach for it to quiet the check on a value that came from a request.
  Such a value wants a schema resolver, which is one guard more.
]]
function M.trusted(value)
  return value
end

--[[ Split a body at its bind placeholders.

  Returns the literal pieces and the placeholder count, so `#pieces` is always
  count + 1. A `?` inside a quoted literal is data rather than a placeholder --
  no statement here has one today, and finding out the hard way later is not
  worth the four lines it costs to be right now.

  `?*` is a variadic slot: one placeholder per value, comma-separated. It is
  what lets a statement whose *arity* is not known until it runs still be
  declared -- an IN list as wide as an account has roles was the last value
  interpolation in the codebase, and it was injectable. The arity is a compile
  key rather than a runtime parameter, so the expansion happens once per width
  per worker and the call is still a table lookup.

  The separator is fixed at `, ` because every position that can take a
  variadic slot is a comma list: an `IN (...)`, a `VALUES (...)` tuple. A slot
  needing anything else is a different feature, not a parameter on this one.
]]
local function split_placeholders(body, arity)
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

      if sub(body, i + 1, i + 1) == '*' then
        if arity == nil then
          fail('?* needs an arity; reach the statement with db:list(): %s', body)
        end

        -- One placeholder is the chunk just pushed; each additional one needs a
        -- separator piece in front of it. Arity is held to at least 1 by
        -- `M.compile`, so this never renders an empty list.
        for _ = 2, arity do
          pieces[#pieces + 1] = ', '
        end

        i = i + 1
      end

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

  -- Three values either way: the SQL for a driver that binds, or the literal
  -- chunks and the format template for one that cannot.
  if style == 'question' then
    return table.concat(pieces, '?'), nil, nil
  elseif style == 'numbered' then
    local out = {pieces[1]}

    for i = 1, count do
      out[#out + 1] = '$' .. i
      out[#out + 1] = pieces[i + 1]
    end

    return table.concat(out), nil, nil
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
local function substitute(text, decl, values, quote, connection)
  return (gsub(text, '{(%w+)(:?%a*)}', function(key, modifier)
    local resolver = decl.idents and decl.idents[key]
    local value = values[key]

    if resolver == nil then
      fail('%s has no identifier named %q', decl.name, key)
    end

    if value == nil then
      fail('%s needs identifier %q', decl.name, key)
    end

    do
      -- Unconditional: `define()` refuses an `idents` entry that is not a
      -- function, so there is no declaration whose identifiers reach the shape
      -- check below without a resolver having spoken first.
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

      `quote` itself is nil for the other caller that wants a bare name: the
      attribution pass in `build()`, which resolves the table a statement
      touches rather than the SQL spelling of it.
    ]]
    if modifier == ':bare' then
      return value
    elseif modifier ~= '' then
      fail('%s: unknown identifier modifier %q on %q', decl.name, modifier, key)
    end

    return quote and quote(value) or value
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
  attribution is a field rather than a parse. `idents` declares `{slot}` names,
  each with the resolver that guards it -- a schema lookup, or `M.trusted` for a
  value the framework writes itself.
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

  --[[ `order` is what fixes the walk through the compile cache and the meaning
    of `db:with(name, ...)`'s positional values, so a declaration that has
    identifiers and no order for them is broken at every use of it.

    Checked here, at load, for the same reason `includes/database/config.lua`
    checks a driver name at resolve rather than at the first query: the failure
    should be at the line that got it wrong, not on whichever request happens to
    reach that statement first.
  ]]
  if decl.idents ~= nil then
    local order, seen = decl.order, {}

    if type(order) ~= 'table' then
      fail('%s declares identifiers and no order for them', name)
    end

    for _, key in ipairs(order) do
      if decl.idents[key] == nil then
        fail('%s orders identifier %q, which it does not declare', name, key)
      end

      seen[key] = true
    end

    for key in pairs(decl.idents) do
      if not seen[key] then
        fail('%s declares identifier %q and leaves it out of its order',
          name, key)
      end

      --[[ Every identifier names the guard it rests on, and `true` is not a
        guard -- it was the spelling for "the shape check alone", which reads
        exactly like a resolved identifier and is one layer rather than two.

        Refused at load, so the question "which identifiers in this codebase
        have a single guard?" is answered by grepping for `trusted` instead of
        by reading every declaration. A new one cannot be added silently, which
        is the whole difference between having audited this once and it being
        closed.
      ]]
      if type(decl.idents[key]) ~= 'function' then
        fail('%s identifier %q needs a resolver: a schema lookup such as '
          .. 'connection:table() or connection:field() when the value comes '
          .. 'from data, or registry.trusted when it is written in a '
          .. 'declaration', name, key)
      end
    end
  end

  --[[ A variadic body is detected once, at load, rather than searched for on
    every compile. Every dialect override is checked too: a statement that is a
    list on one backend and not on another would take `db:list()` on one and
    refuse it on the other, which is a portability break that would only show up
    on whichever backend the test suite does not run.
  ]]
  do
    local variadic = decl.sql:find('?*', 1, true) ~= nil

    for key, value in pairs(decl) do
      if type(value) == 'table' and type(value.sql) == 'string' then
        if (value.sql:find('?*', 1, true) ~= nil) ~= variadic then
          fail('%s is variadic on %s and not on its portable body; ?* has to '
            .. 'be in both or neither', name, tostring(key))
        end
      end
    end

    decl.variadic = variadic
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

-- There is deliberately no `reset()`. Declarations are load-time and immutable,
-- and the framework's own arrive by `require`, which runs once per process --
-- so clearing them would leave `core.begin` and the rest permanently undefined
-- rather than reloaded. The compile cache is derived and could be dropped
-- safely, but nothing needs to, and an entry point nothing exercises is one
-- more thing to be wrong.

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

local function build(decl, driver, values, connection, arity)
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
    body = substitute(body, decl, values, driver.quote_identifier, connection)
  end

  pieces, count = split_placeholders(body, arity)
  sql, chunks, template = render(driver, pieces, count)

  tables = {}

  for i, name in ipairs(decl.tables or {}) do
    if decl.idents then
      -- A statement whose table is an identifier attributes to the table it was
      -- actually compiled for, not to the literal `{table}`. Unquoted, because
      -- this is a name for `includes/database/stats.lua` to classify, not
      -- SQL for a backend to parse.
      name = substitute(name, decl, values, nil, connection)
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
function M.compile(driver, name, values, connection, arity)
  local decl = statements[name]
  local per_driver = compiled[driver.name]
  local node

  if decl == nil then
    fail('%s is not defined', tostring(name))
  end

  -- Without this, a statement with identifiers reached through `run()` fails by
  -- indexing a nil `values` several lines down, which names neither the
  -- statement nor the mistake.
  if decl.idents ~= nil and values == nil then
    fail('%s takes identifiers; reach it with db:with(%q, ...)', name, name)
  end

  --[[ Arity is a compile key, and it is required in both directions.

    A variadic statement reached through `run()` would render one placeholder
    and bind however many values the call passed, which is a silent wrong
    answer rather than an error -- so it is named here. The reverse is cheap to
    check and worth checking: `db:list()` on a fixed statement means the caller
    believes it takes a list, and it does not.

    Zero is refused rather than rendered. `IN ()` is a syntax error on every
    backend, and the empty case is a question about the caller's intent -- no
    roles means no permissions, which is a branch, not a query.
  ]]
  if decl.variadic then
    if arity == nil then
      fail('%s takes a list; reach it with db:list(%q, values)', name, name)
    elseif arity < 1 then
      fail('%s was given an empty list; decide what no values means at the '
        .. 'call site rather than rendering IN ()', name)
    end
  elseif arity ~= nil then
    fail('%s takes no list; reach it with db:run(%q, ...)', name, name)
  end

  if per_driver == nil then
    per_driver = {}
    compiled[driver.name] = per_driver
  end

  node = per_driver[name]

  if decl.idents == nil and not decl.variadic then
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
  -- `define()` has already held it to the declared identifiers.
  for _, key in ipairs(decl.order or {}) do
    local value = values[key]
    local next_node = node[value]

    if next_node == nil then
      next_node = {}
      node[value] = next_node
    end

    node = next_node
  end

  -- Arity is the last level, so a statement that is both variadic and
  -- identifier-bearing keys on the identifiers first and the width beneath
  -- them, which is the order `with()` already walks.
  if arity ~= nil then
    local next_node = node[arity]

    if next_node == nil then
      next_node = {}
      node[arity] = next_node
    end

    node = next_node
  end

  if node.compiled == nil then
    node.compiled = build(decl, driver, values, connection, arity)
  end

  return node.compiled
end

--[[ Compile a string of SQL that was not declared.

  For migrations, the installer, the CLI, and the two statements whose arity is
  not known until they run -- an IN list as wide as an account has roles, a
  UNION with one arm per entity type a tag is attached to. It goes through the
  same renderer as a declaration, so a non-binding driver gets its template, a
  numbered one gets its `$n`, and `{{limit}}` means what it means everywhere
  else. The difference is only that nothing is cached and attribution falls back
  to the tokenizer, which is what that parser is for.
]]
function M.compile_text(driver, sql)
  local pieces, count

  if sql:find('{{', 1, true) then
    sql = expand_macros(sql, driver)
  end

  pieces, count = split_placeholders(sql)
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
