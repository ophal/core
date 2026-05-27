# Ophal - An experimental Lua based CMS/CMF

## What is Ophal?

Ophal aimed to become a highly scalable web platform, easy to maintain, learn, extend and open to improvements.

## Development

Development workflow and release policy: [docs/branching-and-releases.md](docs/branching-and-releases.md).

## Runtime

Ophal now targets OpenResty as its supported web runtime. CGI support has been
removed. Use [nginx.ophal.conf](nginx.ophal.conf) as the starting point for
deployment and the OpenResty-based example Docker image in
[examples/Dockerfile](examples/Dockerfile) for local development.

## Dependencies

Ophal has the following dependencies:

- Seawolf (http://github.com/ophal/seawolf)
- LPEG
- LuaFilesystem
- LuaDBI
- luuid
- dkjson
- LuaCrypto (only if user module is enabled)

## OpenResty runtime model

Ophal runs correctly inside OpenResty, but `0.2.x` is not a fully nonblocking
stack. Database access still goes through synchronous `LuaDBI`, and some
filesystem work still happens on request paths for templates, asset metadata,
sessions, and uploads.

Static asset and template metadata now use short-lived runtime caches to avoid
repeated `stat()` calls on warm requests. The cache TTL defaults to `1` second
and can be tuned through `settings.runtime_cache`.

The supported operational posture for `0.2.x` is low-to-moderate traffic. It
is not presented as a fully nonblocking high-concurrency stack until an
OpenResty-native database path exists.

The OpenResty native-hardening work is complete and documented in
the internal native-hardening notes.

The active next-step architecture work is tracked in
the internal performance-architecture notes.
That plan keeps OpenResty as the only web runtime, treats PostgreSQL as the
required production SQL backend for the performance architecture, and keeps
Valkey only as a future optional accelerator rather than a core dependency.

SQLite remains supported for development, CLI tooling, tests, and low-scale
compatibility work, but it is no longer treated as a peer production backend
for the performance architecture.

For the concrete remaining worker-blocking paths, see
the internal blocking-surface notes.

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
