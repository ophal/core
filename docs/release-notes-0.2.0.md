# Ophal 0.2.0

Ophal 0.2 is a rebuild of how a page is delivered. Content is served from
versioned projections rather than from the normalized schema, anonymous
responses carry real HTTP validators, and the runtime is OpenResty and nothing
else. A warm anonymous page now issues **no database query and no filesystem
operation beyond fourteen `stat` calls**.

It is also a much smaller thing to install. The dependency list went from eleven
entries to three — LuaFilesystem, `cjson` and one database binding — and `cjson`
ships with OpenResty, so a typical site installs **two rocks**, or one on MySQL.

This line replaces 0.1 completely. It is not a drop-in upgrade — read
*Upgrading from 0.1* before deploying it.

The release is tagged `v0.2.0-1`. The suffix is the cut number, in the same form
LuaRocks uses for a rockspec revision, so one string identifies the release in
git and in a rock; there is no separate alpha or beta vocabulary. `0.2` is a
`0.x` major, which is what says the interface may still change.

---

## Requirements

| | |
| --- | --- |
| Runtime | OpenResty, with its bundled LuaJIT. No other Lua runtime is supported. |
| Rocks to install | **LuaFilesystem**, plus one database binding: `lsqlite3` for SQLite, `pgmoon` for PostgreSQL. MySQL needs nothing — `lua-resty-mysql` ships with OpenResty. |
| Bundled with OpenResty | `cjson`, the MD5 and SHA-2 digests, `resty.random`, the cosocket drivers. |
| Database | PostgreSQL for production. SQLite for development, the CLI, tests and low-scale sites. MySQL is supported. |
| nginx configuration | `lua_shared_dict ophal_projection_versions 1m;` in the enclosing `http { }` block. This is the one required directive the shipped `nginx.ophal.conf` cannot carry, because that file is a `server { }` block. |

`./ophal install check` verifies all of it and reports the configured driver.

**PostgreSQL 14 and later default to `scram-sha-256`, and `pgmoon` needs an
OpenSSL binding to authenticate with it** — `lua-resty-openssl` or `luaossl`.
This is the most common first-install failure; nothing in the test suite can
catch it, because the test lab authenticates with `trust`.

---

## Upgrading from 0.1

### Breaking changes

| What changed | What to do |
| --- | --- |
| **CGI is gone.** `index.cgi`, `cron.cgi`, `install.cgi` and the CGI adapter were removed, along with `.htaccess`. | Deploy behind OpenResty. `index.lua` and `cron.lua` are the entry points. |
| **The command line runs under OpenResty.** `lua5.1` is not a supported runtime anywhere, including for `ophal`. | Nothing, unless you invoked the CLI through a Lua interpreter directly. The `ophal` script names `resty` itself. |
| **Driver names mean different bindings.** `sqlite3` is `lsqlite3`; `postgresql` is `pgmoon`. LuaDBI is gone entirely — it read integer columns with 32-bit precision on SQLite and PostgreSQL, and destroyed NULL on MySQL. | Install the new binding. A settings file naming a retired LuaDBI driver is answered with the name that replaced it, rather than failing somewhere inside its first query. |
| **The free database functions were deleted**, not deprecated: `db_query()`, `db_field()`, `db_limit()`, `db_last_insert_id()`, `db_connect()` and the rest. | A custom module reaches the database through `db_connection()` and declares its statements in `modules/<name>/statements.lua`. |
| **`seawolf`, LPeg, luuid and LuaSocket are no longer available.** | A custom module using `seawolf.text`, `seawolf.variable` or `seawolf.fs` moves to `includes/text.lua`, `includes/util.lua` and `includes/fs/path.lua`. |
| **Sessions from 0.1 will not parse.** The store holds JSON, not executable Lua. | Nothing. Such a session reads as *no session*, so everyone signs in once and nobody sees an error. |
| **A failed render answers 500.** A missing theme function or an unreadable template used to be printed into the page at HTTP 200. | If a theme calls a theme function a disabled module provides, it now fails loudly. The detail goes to the error log. |
| **`modules/boost` was removed.** Its cache key ignored the query string, so every `?page=` collided, and it served authenticated pages to anonymous visitors. | Nothing replaces it. The projection and payload caches made the render the cheap part, and HTTP validators let an intermediary answer instead of Ophal. |
| **Mobile detection was removed.** `settings.mobile` and `themes/mobile/` are gone. | Use responsive CSS. The setting is ignored rather than rejected, so a stale settings file still boots. |
| **`settings.micro_cache` was retired.** It answered 304 to any client whose `If-Modified-Since` was within five seconds of *now*, with no reference to the page. | Nothing. Real validators replaced it. |
| **`settings.sessionapi.lock_ttl` is inert.** There is no lock any more. | Nothing. The key is still accepted. |

### Steps

1. Install OpenResty, LuaFilesystem and your database binding.
2. Add `lua_shared_dict ophal_projection_versions 1m;` to the `http { }` block.
   Without it Ophal falls back to per-worker state silently, which serves stale
   pages after a write on a multi-worker site.
3. Run `ophal migrate apply` to create the projection and job tables.
4. **Schedule `/cron`.** This is not a background nicety: projections are built
   by the drain. A site that never runs cron serves correct pages from the
   normalized fallback and pays for each rebuild inside a visitor's request.
   `ophal jobs status` reports how much is waiting.
5. `ophal install check` to confirm the result.

---

## What's new

### Delivery

- **Projection-backed reads.** Routes, content, the front page and tag listings
  are served from projection tables keyed by a version, with automatic fallback
  to the normalized schema when a projection is stale or missing.
- **Two cache tiers.** A per-worker payload and version cache, and a
  `lua_shared_dict` version tier that publishes writes across workers. The
  payload cache is bounded per projection and reports hits, misses, stale
  lookups, evictions and occupancy.
- **HTTP cache semantics.** An anonymous GET that returns 200, sets no cookie
  and was built from at least one projection carries an `ETag`, a
  `Last-Modified` and `public, max-age=0, s-maxage=0, must-revalidate`; a
  matching `If-None-Match` is answered 304 with no body. The validator is the
  set of projection versions the response was built from, so it describes the
  page rather than the clock.
- **A response built from a normalized table is never given a validator.**
  Fallback pages and service responses stay uncacheable, which is what keeps a
  revalidation honest.
- **Lazy sessions.** A visitor with no valid cookie receives no id, no cookie
  and no file until something writes to `_SESSION`. The `Set-Cookie` was the
  expensive half: a response carrying one can never be shared by a downstream
  cache, whatever `Cache-Control` says.

### Publishing

- **Content can be deleted over HTTP**, through `content/save/<id>` with
  `{"action":"delete"}`. Existence is checked before access, `delete own
  content` is required, and ownership is compared.
- **Uploads assemble in place.** A chunk is written straight to its offset in
  one staging file and finalized with a rename, so reassembly moves no bytes
  through Lua. A request body nginx already buffered to disk is renamed rather
  than copied. File type inspection runs on the job queue.
- **Deferred work.** A projection that is stale or has never been built is
  queued rather than rebuilt inside the request that noticed it. `/cron` drains
  the queue; a queue that has visibly stopped draining falls back to the inline
  rebuild, so a site whose cron dies recovers rather than deferring forever.

### Operations

- `ophal install init` scaffolds `settings.lua` and `vault.lua`, defaulting to
  PostgreSQL. `ophal install check` verifies dependencies and reports the driver.
- `ophal migrate status` / `ophal migrate apply`, with a per-dialect ledger for
  all three backends.
- `ophal jobs status` reports the deferred queue.
- `/cron` is guarded twice: `allow 127.0.0.1; deny all;` in the shipped server
  block, and a token from `vault.cron.token` checked against `?token=` or an
  `X-Ophal-Cron-Token` header.
- Structured logging with levels and context in `includes/log.lua`.

---

## Performance

Every number is measured end to end — nginx, bootstrap, routing, theme and
driver — and pinned by an assertion, so a regression fails the build rather than
being noticed later. They are identical on SQLite, PostgreSQL and MySQL.

| Request | Queries | Of which normalized |
| --- | --- | --- |
| Warm anonymous front page, content page, route alias, tag listing | **0** | 0 |
| Warm signed-in front page | **0** | 0 |
| Content create or update | 15 | 5 |
| Front page on a stale projection | 4 | 2 |
| Second reader inside the same stale window | 2 | 2 |

Zero is reachable because connecting is lazy: a request served entirely from
projection caches never opens a socket.

An anonymous request costs the filesystem **nothing at all** and leaves no
session file behind. Rendering the page costs at most **14 `stat` calls** and no
reads — thirteen template lookups and one asset lookup, with every template
already compiled and cached by path and modification time. Changing a template
adds four opens, four reads and 1,928 bytes on the next request and nothing
after it.

Fourteen is the ceiling rather than the steady state: the metadata caches hold
for `settings.runtime_cache.stat_ttl` seconds, one by default, so a busy site
pays somewhere between 0 and 14 per render.

Two replacements are worth their own line:

- **Password hashing is 129x faster.** Ophal iterates a digest 10,000 times by
  default and resolved it through a chain of optional rocks, falling through to
  a bundled pure-Lua SHA-256 — which was the live path on every documented
  install, because OpenResty's own digests were never asked for. A sign-in cost
  **676 ms of blocked worker**; it now costs **5.2 ms**, with a byte-identical
  digest, so stored hashes still verify.
- **Request parsing is 15x faster.** `seawolf.text.explode` compiled a fresh
  LPeg grammar on every call, three times per request. Query strings and cookies
  now use the nginx primitives: 28.6 µs down to 1.9 µs.

---

## Security

An audit fixed one live vulnerability and three weaknesses:

- **Stored XSS in the file module.** `theme.file` and `theme.file_info` rendered
  a filename raw, and a filename arrives from the request. Its only guard was a
  *path* check, which correctly has no opinion about `<`.
- **Session fixation.** An id planted before authentication carried the
  authenticated session. The id is rotated at the privilege change.
- **Unpinned secret generation.** Session ids, CSRF tokens, password salts and
  the installer's site hash now come from one CSPRNG, with no `math.random`
  fallback — nothing downstream can tell a weak secret from a strong one.
- **The CSRF token was compared with `==`.** It uses a constant-time comparison.

The SQL surface was closed and then locked open-ended:

- No application code holds SQL text. Statements are declared and compiled once
  per driver; the only `:execute()` call sites left are the migration runner and
  the method's own definition.
- Every SQL identifier names the guard it rests on. A declaration must name
  either a schema resolver or an explicit `trusted` marker; the shorthand that
  named neither is refused at load.
- A lint refuses a SQL literal carrying a format slot, SQL adjacent to `..`, and
  `:execute()` outside the allowlist. It parses Lua rather than reading lines,
  so a statement split across two lines cannot hide from it.
- An injection probe runs against all three live backends in every test run —
  value payloads, identifier payloads, the bound path, the escaped path, ad-hoc
  SQL and a second-order case that stores a payload and reads it back as an
  identifier.

---

## Known limitations

- **SQLite is bounded by write concurrency, not volume.** Several workers share
  one file, and a public read can write, because a stale projection rebuilds
  from inside a GET. Run PostgreSQL in production.
- **MySQL returns genuinely 64-bit columns as strings.** Every id and foreign
  key is `INT`, which the driver converts, so authorization comparisons are
  unaffected. Timestamps, file sizes and projection versions arrive as strings;
  arithmetic coerces them and comparison does not.
- **A permission change needs a worker restart.** Nothing in the application
  writes roles or permissions, so there is no write path to invalidate against.
- **`modules/entity`'s delete path is unfinished.** The module is enabled in no
  shipped settings file; content and tags delete through their own modules.
- **There is no access log and no last-login record.** Structured logging
  exists and no module calls it yet.

The full list, with the reasoning and the measurements behind each judgement,
is in `TODO.md` at the repository root.

---

## Verification

The unit suite is 33 files. The smoke suite is 356 scenarios — 32 base plus 108
against each of SQLite, PostgreSQL and MySQL — run against real servers, with
query and filesystem budgets pinned and the injection probe included. Scenario
counts are asserted per backend, so coverage lost in a merge fails the build
instead of looking like a clean run.
