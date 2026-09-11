# TODO

Work that is known, understood, and deliberately not blocking a release.

Production blockers do not live here. This is the list of things that are
either optimizations without a measurement behind them, coverage gaps in paths
that are not core operations, or documentation that has fallen behind the code.
Each entry says why it is not urgent, because that judgement is the part that
goes stale.

Two of these turned into numbers on 2026-09-11 and one turned into a closed
bug. Where a measurement replaced an argument the entry says what was measured
rather than being deleted, because the reasoning is what a future reader has to
re-derive otherwise.

## Correctness limits, bounded and understood

### MySQL returns genuinely 64-bit columns as strings

`lua-resty-mysql` 0.27 leaves `BIGINT` unconverted -- `converters[0x08]` is
commented out in the library, deliberately, because a 64-bit integer does not
fit a Lua number exactly. It cannot be repaired in the driver: the rows carry
no column types, and the only available rule would be "a string of digits is a
number", which would rewrite a title of "2024".

Audited 2026-09-10, and the dangerous class is closed:

- Every id and foreign key is `INT` in the MySQL schema, which that driver does
  convert, and `core.last_insert_id` is `LAST_INSERT_ID() + 0.0`. That is what
  closes the authorization case -- `content.user_id == account.id` reading
  `"2" == 2` meant "edit own content" could never grant.
- What is still `BIGINT` is timestamps, file sizes and projection versions.
  Arithmetic coerces, `..` coerces, and `os.date`'s second argument goes
  through `lua_tonumber`, so a numeric string is accepted. `<` and `>` against
  a number raise, which is loud. Only `==` is silent.
- The three `==` sites reachable on those values -- `includes/http_cache.lua`,
  `includes/projection.lua`, `includes/route.lua` -- all compare a version
  against another version from the same funnel, and `projection.version()`'s
  reader already calls `tonumber`.

So: keep `tonumber` in front of any new comparison of a timestamp, a size or a
version, and prefer `INT` for a new column that does not need the range. Revisit
if a schema gains a column that is genuinely 64-bit and gets compared.

### A composed relation name is validated in parts, not whole

`rel_{table:bare}_{parent:bare}` holds each part to `^[%a_][%w_]*$` and resolves
each through the connection's schema, so `content` and `tag` can both resolve
while `rel_content_tag` does not exist. That is a SQL error, not an injection:
neither part can carry a quote, a comment or a semicolon. Resolving the
composition would mean a second resolver mechanism for one declaration.

## Performance

This section was "with no measurement behind it", and on 2026-09-11 three of its
entries stopped being that. Where a number arrived it is in the entry, and where
it settled the question the entry says so instead of staying open forever.

### Connection object reuse across requests

The plan's old item 3 asked for this to remove two connection pragmas and to
give `db_query()` a statement cache. Both are gone -- the pragmas with lazy
connect in 8.5, `db_query()` with the layer -- and the *socket* is already held:
`router.release_all()` calls the driver's release at request end, pgmoon's
`keepalive()` when `sock_type == 'nginx'` and `lua-resty-mysql`'s
`set_keepalive()`. So connect-and-authenticate is already amortized.

What is left is narrow, and narrower than it reads. The per-connection schema
cache behind `Connection:field()` and `Connection:table()` is rebuilt each
request -- but it is only consulted by a `with()` statement, so it costs **one**
`core.table_schema` read on a request that signs in, deletes, or loads a row by
field, and **zero** on a warm anonymous page, which opens no connection at all.

The other half is pgmoon's lack of named prepared statements, so every execute
re-parses server-side. It is worth about 1.4x on the bound path and it means
vendoring a patched pgmoon -- which is a dependency decision, not an
optimization, and belongs under "Not scheduled" unless the project decides to
carry a fork.

### Phase 5's authoring half

Moving authoring side effects onto the job queue. A create is 15 queries and an
update 15, against 0 for a warm read. Nobody has complained about 15.

### Template and asset metadata misses -- measured 2026-09-11

`includes/theme.lua` and `includes/common.lua` are TTL caches over
`lfs.attributes`; a template compile miss additionally does a blocking
`io.open`. This entry said the actual TODO was that nothing could state a budget
over it, because `includes/fs/stats.lua` had no bucket for it. It has one now --
`render`, plus a `stat` op -- and the numbers are:

| front page | stat | open | read | bytes |
| --- | --- | --- | --- | --- |
| warm | 13 template + 1 asset | 0 | 0 | 0 |
| after the templates change | 14 | 4 | 4 | 1,928 |

So a warm render's entire filesystem cost is asking fourteen times whether a
file has changed, and the compile cache absorbs everything else. `db_render_warm`
and `db_render_compile_miss` pin both rows, on all three backends.

Two things that matter more than the totals:

- The stat TTL defaults to **one second** and is compared with `os.time()`, so
  two requests inside the same second share one answer and two a second apart do
  not. The smoke profile sets it to 0 precisely so the budget is a number rather
  than a measure of how fast the harness ran. A real site pays somewhere between
  0 and 14 stats per render depending on its traffic.
- Nothing is read or opened on a warm request, so there is no blocking `io.open`
  on the hot path to remove. What is left to optimize is fourteen `stat(2)`
  calls, which is not a ranking item any more.

### Cron session cleanup

`session_destroy_expired()` in `includes/session.lua` scans the session
directory with `lfs.dir()` and stats each entry. It runs from cron, not from a
page render.

Phase 7 changed its premise rather than its code: anonymous requests no longer
leave session files at all, so the directory this walks should now be a small
fraction of what it was. Measure before optimizing -- the work may already have
gone away.

**Measured 2026-09-11, and it has.** The walk is one `lfs.dir` plus **one stat
per session-shaped entry** and nothing else: `.`, `..` and any foreign file are
matched on their names and skipped without a syscall, so the cost is
proportional to Ophal's own files rather than to the directory. Since Phase 7
those files exist only for visitors who wrote to a session -- signed in, or
asked for a CSRF token -- rather than for every visitor who ever arrived. There
is no optimization here worth making; there is a number.

The session store gave it two more things to sweep on 2026-09-10 — orphaned
`<id>.ophal.tmp.<hex>` from a write that died between `io.open` and `os.rename`,
and legacy `<id>.ophal.lock` files, kept for one release so an upgraded site
cleans itself. Neither changes the shape of the walk, and **neither had ever
run** until `tests/unit/test_session.lua` drove them on 2026-09-11. Both reap
correctly; removing either branch turns `sweep_removes_only_what_expired` red.

### A comment projection -- measured 2026-09-11, and not worth building

The number recorded here on 2026-09-09 was 2 queries and 1 normalized, and it
was taken at **one comment**, which says nothing about the shape. The service
reads normalized `comment` once and then calls `user_mod.load(row.user_id)` per
row, so whether it is flat or linear depends entirely on the user module's
per-worker cache. Finding 3c sharpened the question rather than answering it:
the endpoint is explicitly uncacheable now, so every request reaches Ophal.

Measured at 33 comments over 2 distinct authors, identically on SQLite,
PostgreSQL and MySQL:

| | total | normalized |
| --- | --- | --- |
| 1 comment, warm | 2 | 1 |
| 33 comments, warm | 1 | 1 |
| 33 comments, cold worker | 4 | 4 |

**It is flat in the number of comments and linear in the number of distinct
authors, once per worker.** A projection would buy nothing on a warm worker and
would save `(distinct authors)` reads on a cold one -- against the cost of a
table, a migration, a version key, a fallback and an invalidation path on every
comment write. That is the wrong trade, so this is closed rather than deferred.

What does scale with rows is the render and the JSON encode, neither of which a
projection touches: `tests/bench/json_bench.lua` has a 32-comment response at
about 4 ns a byte through cjson. Reopen this only if the *rendering* of a long
thread starts to matter, which is a different piece of work.

`db_comment_fetch_many` and `db_comment_fetch_many_cold` keep the claim honest,
and they assert the *relationship* rather than a pinned number -- they sit below
the write barrier, where an absolute budget would be meaningless.

### Widening projections past route, content and tag

Phase 3's one incomplete part. Nothing on a measured anonymous path reads a
normalized table any more, so there is no candidate with a measurement behind
it. Follow evidence rather than the list; the rest of the normalized schema is
authoring-path work that no anonymous page touches.

## Delete

### `modules/entity`'s delete path is unfinished

**Content itself can be deleted as of 2026-09-11.** `modules/content`'s
`save_service()` has a `delete` arm, reached with `{"action":"delete"}` on
`content/save/<id>`, shaped exactly like `modules/tag`'s: existence checked
before access, `delete own content` required and ownership compared.
`db_content_delete` and the five scenarios around it cover it on all three
backends, including that the node leaves the front page -- the projection half
-- and that another author's node is refused and survives the refusal.

What is left is the entity module's own path, kept here as the list of what to
finish when content and comments become entities rather than as an argument for
removing anything.

- `modules/entity` is enabled in **no** settings file — not `settings.lua`, not
  `examples/settings.lua`, not either smoke profile.
- Enabling `modules/entity` does not give you a working delete, it relocates the
  failure:
  - `entity/remove` has `page_callback = {'delete_service'}` and
    `delete_service` is never defined anywhere — `modules/entity/init.lua:61` is
    the only occurrence of the name. The route raises "attempt to call a nil
    value".
  - `delete_page()` reassigns `entity = ophal.modules[info.module].load(entity.id)`
    with no check afterwards, so a missing id crashes on `entity.title` rather
    than answering 404. That is the third instance of a bug already fixed in
    `modules/tag` and `modules/comment`.
  - `_M.delete()` reads `config[entity.type]` where `config = settings.entity`,
    and `settings.entity` is assigned nowhere in the repo.
  - The `rel_<type>_<parent>` tables `entity.delete_relation` names exist in no
    schema on any backend. The one real relation table is `field_tag`, which
    does not follow that convention.

`modules/tag` is unaffected and deletes correctly through its own `tag/delete`
and `tag/service` with `action=delete`, and `modules/content` now does too.

One thing to know before touching any of it: `get_entity_type_info()` memoizes
into a closure upvalue, and `entity_type_info_cache_clear()` is the only way
back. A test that registers a module after the first call has to clear it, which
is why `tests/unit/test_entity_contract.lua`'s `blocks_alter` block does.

**`modules/entity` stays.** An earlier version of this entry recommended
deleting it as dead code; that was reversed on 2026-09-10 — entities are the
direction, and content and comments are expected to become them. Keep the four
defects above as a list of what to finish, not as an argument for removal. One
of them is already closed: `blocks_alter()` compared `route_arg(0)` against the
`pairs` **key** of `parents` rather than the value, so the "add new <type>"
block had never rendered; it iterates the values now and
`tests/unit/test_entity_contract.lua` covers it.

## Recently closed, kept for the reasoning

### The `module()` leak class — closed at its funnel, 2026-09-11

This entry described one leak: `modules/comment`'s `fetch_service` assigning
`list` without `local`, so one visitor's comment list survived on
`ophal.modules.comment.list` for the worker's lifetime.

Scanning every file that calls `module()` found **five**, not one:

| site | what leaked |
| --- | --- |
| `modules/comment` `fetch_service` | `list` — a visitor's comment list |
| `modules/user` `route()` | `items` — the route table |
| `modules/content` `route()` | `items` |
| `modules/file` `route()` | `items` |
| `modules/content` `save_service()` | `_` |

The fifth was found by the guard rather than by reading. `module_load()` in
`includes/module.lua` now seals a jailed module's table once it has loaded: its
`__newindex` raises, naming the module and the key. `__newindex` fires only for
keys a table does not hold, and by the end of loading the table holds exactly
the module's declared surface — so "undeclared" needs no whitelist and cannot
drift.

Writes only. A strict `__index` would also catch an undeclared *read* — the bare
`comment` that `fetch_service` passed to `comment_access` for years — but
`module_invoke_all()` probes `m[hook]` for every module and every hook, so
raising on a missing key would mean `rawget` at every feature probe in the
codebase. The read half is a nil handed to something that does not look at it.

**Still open, and named here so it is not rediscovered:** `modules/system`,
`modules/tag` and `modules/entity` keep their surface on a file-local `_M`, so a
bare assignment there writes a worker-scoped *global* instead. Same class,
different door; the fix is a strict environment over the jailed globals, which
is a larger change than this was.

## Coverage

### `modules/menu` is in no smoke profile — closed 2026-09-11

It was the same shape the comment module was in, and it was hiding the same kind
of thing. Two findings came out of closing it.

**Nothing in the repository renders a menu.** `theme.menu` is defined only by
`modules/menu`, and the one caller of `theme{'menu', ...}` is `modules/tag`'s
`theme.tags_menu()`, which no shipped template calls. So enabling the module in
a profile proves nothing on its own; the profile's theme has to ask for a menu,
which it now does.

**The menu was worker state decided by whichever request warmed the worker.**
`get_menus()` memoized into a file upvalue, and `modules/tag`'s `menus_alter()`
adds a `Tags` link only when `user_mod.is_logged_in()` — so a worker whose first
request was signed in served that link to every anonymous visitor afterwards,
and a worker warmed anonymously withheld it from everyone signed in. Under
`lua_code_cache on`, "afterwards" is the rest of the worker's life. It is the
shape `includes/mobile.lua` was deleted for. The menus are rebuilt per request
through `includes/request_state.lua` now, which also stops `theme.menu` eating
its own definitions — it reads `v[1]` and then writes `v[1] = nil`, which is
destructive for a table-valued entry it does not own.

`db_menu_renders`, `db_menu_is_empty_for_anonymous`, `db_author_menu_has_tags`
and `db_menu_not_leaked_to_anonymous` cover it, the last deliberately following
a signed-in request so a regression shows up as a leak rather than as an absence.

### `lorem_ipsum` and `test` are unexercised

Both are development modules and neither is in a profile. That is probably
correct, but nobody has written down that it is a decision rather than an
oversight. This entry is that record.

## Documentation drift

Ophal keeps design and planning notes as **local working documents that are not
in the repository**, so they fall out of step with the code silently and are
re-checked at each release. They were re-checked on 2026-09-11.

Nothing tracked should cite them. A tracked file that links or refers to a path
git does not carry is a dangling reference for every reader who clones, and
`tests/unit/test_repo_references.lua` fails the build on one.

The pattern worth noticing, and the reason this entry survives its own cleanup:
every instance of the drift was a *ranking* that outlived the thing it ranked. A
document saying "X is the dominant cost" goes stale silently, where one saying
"X costs N, measured on this date" tells a reader when to distrust it.

## The test suite's own rules

Two things that are properties of the harness rather than of Ophal, and that
have each cost a session.

### A budget below the write barrier is refused

A pinned budget is a statement about warm caches, and every projection is
versioned by the unix second its source last changed -- so whether an earlier
scenario's write lands inside the next reader's second is timing. Three
content-creating scenarios inserted mid-file on 2026-09-10 moved
`db_tag_after_update` from 1 normalized read to 4, and it showed up on **MySQL
only, in one run**. A suite that catches that probabilistically does not catch
it.

`budget_barrier` in `tests/smoke/openresty_smoke.sh` closes the budgets partway
down `db_profile.sh`: every budget helper fails below it, naming the scenario.
So a scenario that writes goes below the barrier -- which is where a new one
lands anyway -- and pinning a budget there is a deliberate move of the line
rather than a silent bet. Bash cannot see that a scenario writes, so this
enforces the half that is enforceable; the other half is this paragraph.

### `persistent_interleave` can flake

It failed once on 2026-09-10 holding a response that was a correct 200 -- it had
read request B's output where it wanted A's -- and passed on re-run. It is the
only genuinely concurrent scenario in the suite: two backgrounded curls against
one worker, asserting their timestamps overlap. Treat a lone failure as a flake
and re-run before investigating. A second occurrence is worth a look at how it
captures each request's output, not at the request state it is testing.

## Not scheduled, deliberately

Kept so the list is closed rather than merely long.

- **lua-resty-lmdb** for the projection L2 tier. It is an nginx C module, so
  adopting it means Ophal can no longer run on a stock OpenResty package.
- **Redis / Valkey.** Reverses the recorded design direction: no Redis
  dependency, Valkey documented only as a future optional accelerator.
- **`lua-resty-mysql-fast` / `lua-resty-redis-fast`.** Commercial OpenResty
  subscription libraries, not available to this project.
- **`client_max_body_size`** in the shipped `nginx.ophal.conf`. INSTALL.md
  explains what it bounds and why it matters for chunked uploads; the shipped
  server block deliberately does not pick a number for the operator.
- **A patched pgmoon with named prepared statements.** Worth about 1.4x on the
  bound path, and it means carrying a fork of a dependency -- which is a
  packaging decision rather than an optimization, and the opposite of the
  direction the last release went. Revisit only if the query path becomes the
  measured bottleneck on PostgreSQL.
