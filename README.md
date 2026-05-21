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

The current hardening work is tracked in
the internal native-hardening notes.
The remaining focus is validation guardrails and any further low-risk cleanup
on synchronous file-heavy paths such as uploads and boost caching.

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
