# AGENTS

## Scope

This file captures durable repo context for future agent sessions.

## Current Goal

The current product goal is the architecture upgrade. Treat
`docs/architecture-upgrade-plan.md` as the main implementation roadmap.

## Branch And Release Context

- `master` is the public trunk.
- The branch and release workflow is documented in
  `docs/branching-and-releases.md`.
- The planned next development and release line for the architecture work is
  `0.2.x`.
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

## Runtime Adapter Slice Status

- The first architecture-upgrade implementation slice is in progress in the
  working tree on `0.2.x`.
- The active work introduces a runtime adapter boundary for CGI and `nginx`
  transports.
- The main touched files are:
  `includes/bootstrap.lua`, `includes/server/adapter.lua`,
  `includes/server/cgi.lua`, `includes/server/nginx.lua`, and
  `includes/server/init.lua`.
- The goal of that slice is to normalize request data once per request and keep
  legacy helpers such as `header()`, `write()`, `redirect()`, `request_uri()`,
  `request_path()`, `request_get_body()`, `_GET`, and cookie helpers delegating
  through the active adapter.

## Validation Status

- `git diff --check` passed after the runtime-layer edits.
- A `lua5.1` syntax-only pass over all tracked `*.lua` and `*.cgi` files passed
  at the time this status was recorded.
- CGI smoke automation exists in `tests/smoke/cgi_runner.lua` and
  `tests/smoke/cgi_smoke.sh`.
- OpenResty smoke automation exists in `tests/smoke/openresty_runner.lua` and
  `tests/smoke/openresty_smoke.sh`, and the manual checklist remains in
  `docs/runtime-smoke-checklist.md`.
- The smoke harnesses validate cleanly at the file level
  (`bash -n`, `loadfile`, `git diff --check`).
- CGI smoke execution passes for the planned scenarios on this workspace:
  front page, alias route, prefixed path and query handling, 404, request
  metadata, GET and POST body handling, redirects, cookie append behavior,
  output buffering, and `cron.cgi` boot.
- OpenResty smoke execution also passes for the same transport-parity scenarios
  on this workspace.
- The current workspace uses a local smoke-only vendor runtime under
  `tests/smoke/vendor/` to provide Lua dependencies needed by the harnesses,
  including a vendored `seawolf` checkout and a small `uuid.lua` shim.
- The OpenResty validation exposed and drove two compatibility fixes in the
  working tree: guarded `exit_ophal()` use on early bootstrap failure in
  `includes/bootstrap.lua`, and replacing bare `goto` usage with `go_to` in the
  core tree while keeping `_G['goto']` as a legacy alias.

## Resume Guidance

- Resume on `0.2.x`.
- Preserve the runtime-adapter work already in the working tree; do not discard
  `includes/server/adapter.lua` or the related server-layer edits.
- Preserve the smoke harness files under `tests/smoke/` and
  `docs/runtime-smoke-checklist.md`.
- Preserve the local smoke vendor runtime under `tests/smoke/vendor/` unless
  replacing it with a committed or documented dependency-install path.
- The runtime-adapter slice now has CGI and OpenResty smoke coverage in this
  workspace. The next step is to decide how to commit the smoke harness and
  vendor strategy, then move to the next architecture slice.

