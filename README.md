# Ophal - An experimental Lua based CMS/CMF

## What is Ophal?

Ophal aimed to become a highly scalable web platform, easy to maintain, learn, extend and open to improvements.

## Releases

Current release: **Ophal 0.2.0**, tagged `v0.2.0-1`.

Release notes:
<https://github.com/ophal/core/blob/v0.2.0-1/docs/release-notes-0.2.0.md>

0.2 replaces 0.1 completely and is not a drop-in upgrade. The notes carry the
breaking changes and the upgrade steps; read them before deploying over an
existing site.

## Development

Development workflow and release policy: [docs/branching-and-releases.md](docs/branching-and-releases.md).

## Runtime

Ophal now targets OpenResty as its supported web runtime. CGI support has been
removed. Use [nginx.ophal.conf](nginx.ophal.conf) as the starting point for
deployment and the OpenResty-based example Docker image in
[examples/Dockerfile](examples/Dockerfile) for local development.

## Dependencies

Ophal has the following dependencies:

- LuaFilesystem
- lsqlite3 (SQLite) or pgmoon (PostgreSQL); MySQL uses the `lua-resty-mysql`
  that ships with OpenResty

JSON needs no dependency: Ophal uses `cjson`, which ships with OpenResty.
Ophal runs on OpenResty and its LuaJIT only -- the `ophal` command line runs
under `resty` as well, so there is one runtime rather than two.

The user module needs no cryptography rock, and neither does any other
algorithm it offers. Passwords are hashed through `includes/digest.lua`, which
uses the `resty.md5`, `resty.sha1` and `resty.sha224` through `resty.sha512`
bindings that ship with OpenResty -- so every value
`settings.user.password_hash.algorithm` accepts works out of the box.

This used to say the same thing for a different reason: a pure-Lua SHA-256
shipped with Ophal and no binding was needed. It was also the *live* path,
because nothing asked OpenResty, and a 10,000-iteration hash cost 676 ms of
blocked worker per sign-in against 5.2 ms now. The digests are identical, so
hashes stored by older versions still verify.
`tests/bench/digest_bench.lua` is the measurement.

## OpenResty runtime model

Ophal runs correctly inside OpenResty, but `0.2.x` is not a fully nonblocking
stack. SQLite is synchronous whatever the binding -- it has no socket -- and some
filesystem work still happens on request paths for templates, asset metadata,
sessions, and uploads.

Static asset and template metadata now use short-lived runtime caches to avoid
repeated `stat()` calls on warm requests. The cache TTL defaults to `1` second
and can be tuned through `settings.runtime_cache`.

On PostgreSQL and MySQL the request path does not block on the database.
`pgmoon` and `lua-resty-mysql` are cosocket drivers, so a query yields the
worker rather than holding it, and a warm anonymous page issues no query at
all -- Ophal connects on the first statement, so such a request opens no socket.

SQLite is the exception, and that is a property of SQLite rather than of the
driver: there is no socket to yield on, and several workers contend for one
file's write lock. It is supported for development, the CLI, tests and
low-scale sites rather than as a peer production backend.

PostgreSQL is the required production backend for the performance architecture.
Valkey is a possible future accelerator, not a dependency.

The measured budgets, the remaining blocking paths and the upgrade notes are in
the release notes linked above.

## CLI

The repository includes a small `ophal` command-line entrypoint:

```sh
./ophal help
./ophal cache clear
./ophal sha256 mypassword
./ophal install check
./ophal install init ./mysite --site-name "My Site"
./ophal migrate
./ophal migrate status
./ophal module enable comment
./ophal module disable comment
```

`install check` verifies required Lua dependencies and reports local config
state. `install init` scaffolds `settings.lua`, `vault.lua`, and the files
directory for a new local site.

`module enable/disable` persists local overrides in `settings/modules.lua`,
which is ignored by git by default so it can stay workspace-specific.

`migrate` applies registered framework and module migrations and initializes the
local migration tracking table when needed.
