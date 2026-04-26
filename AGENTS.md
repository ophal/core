# AGENTS

## Scope

This file captures durable repo context for future agent sessions.

## Current Goal

The architecture upgrade is effectively complete on `0.2.x`. Treat
`docs/architecture-upgrade-plan.md` as the historical implementation roadmap
and current status summary for that work.

## Branch And Release Context

- `master` is the public trunk.
- The branch and release workflow is documented in
  `docs/branching-and-releases.md`.
- The active development and release line for the upgrade work is `0.2.x`.
- Do not introduce a `1.0.x` development branch for the current upgrade unless
  the project is explicitly moving into `1.0` stabilization.

## Editing Guidance

- Codex-specific note: if `apply_patch` is unavailable because of environment
  or sandbox restrictions, use `python3` for scoped file edits instead.
- Keep edits narrow and avoid rewriting unrelated files.
- Do not touch local or user-specific files unless explicitly requested.

## Local Cautions

- Treat files such as `settings.lua` and `.cuyboxrc` as local workspace files.
- Avoid committing unrelated untracked files while working on docs or core
  changes.

## Key Documents

- `docs/architecture-upgrade-plan.md`
- `docs/branching-and-releases.md`

## Current Status

- The `0.1` integration is complete: `0.1` was merged into `master` via
  `merge/0.1-into-master`, and `0.2.x` was created from the merged `master`.
- Freeze tags already exist for that transition:
  `pre-merge-master-2026-03-22` and `pre-merge-0.1-tip-2026-03-22`.
- The current checked-out branch is `0.2.x`.

## Runtime Status

- The runtime adapter and persistent-runtime work are complete on `0.2.x`.
- Ophal now supports OpenResty only as its web runtime.
- CGI support has been removed, including `index.cgi`, `cron.cgi`,
  `install.cgi`, and `includes/server/cgi.lua`.
- The active runtime files are:
  `includes/bootstrap.lua`, `includes/server/adapter.lua`,
  `includes/server/openresty.lua`, and `includes/server/init.lua`.
- The public web entrypoints are `index.lua` and `cron.lua`.

## Validation Status

- The full unit suite passes on `0.2.x`.
- OpenResty smoke automation exists in `tests/smoke/openresty_runner.lua` and
  `tests/smoke/openresty_smoke.sh`, and the manual checklist remains in
  `docs/runtime-smoke-checklist.md`.
- The OpenResty smoke suite passes for front page, alias route, path and query
  handling, 404s, request metadata, GET and POST body handling, redirects,
  cookie append behavior, output buffering, cron boot, and persistent-worker
  isolation.
- The current workspace uses a local smoke-only vendor runtime under
  `tests/smoke/vendor/` to provide Lua dependencies needed by the harnesses,
  including a vendored `seawolf` checkout and a small `uuid.lua` shim.

## Resume Guidance

- Resume on `0.2.x`.
- Preserve the OpenResty runtime and smoke harness files under `tests/smoke/`
  and `docs/runtime-smoke-checklist.md`.
- Preserve the local smoke vendor runtime under `tests/smoke/vendor/` unless
  replacing it with a committed or documented dependency-install path.
- The next work is no longer the architecture upgrade itself. Focus on release
  framing, documentation quality, and any post-upgrade stabilization needed for
  the `0.2.x` line.
