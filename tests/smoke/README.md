# Smoke Harness

These smoke tests validate the OpenResty runtime without depending on the
workspace `settings.lua`.

## Local Runtime Setup

The harnesses expect a local vendor runtime under `tests/smoke/vendor/`.
That directory is intentionally ignored by git.

Build it with:

```sh
bash tests/smoke/setup_vendor_runtime.sh
```

The setup script downloads and unpacks the packaged Lua modules used by the
harnesses and builds `lsqlite3` from source.

It fetches two packages: `lua-filesystem`, which Ophal requires, and
`lua-dkjson`, which it does not — that one is vendored solely for
`tests/bench/json_bench.lua`, the measurement that retired it.

Requirements:

- `apt`
- `dpkg-deb`
- `git`
- network access

## Database backends

The suite runs one OpenResty instance with no database, covering the runtime
itself, and then one instance per database backend. The database profiles all
source the same scenario list -- `tests/smoke/db_profile.sh` -- so
"the same scenarios pass on PostgreSQL" is a property of one file rather than of
several lists kept in step by hand. Each profile asserts its own scenario count
for the same reason.

SQLite needs nothing. PostgreSQL and MySQL come from the vendored lab:

```sh
bash tests/bench/setup_backends.sh all
```

Without it those two profiles are skipped, by name, and the summary line says
how many ran. `OPHAL_SMOKE_REQUIRE_BACKENDS=1` turns a skip into a failure, for
a build that is supposed to have them.

Each profile also runs `tests/bench/injection_probe.lua` against its own
backend, so the injection surface is checked on every run rather than when
somebody remembers to.

## Run

```sh
bash tests/smoke/openresty_smoke.sh
```

`openresty_smoke.sh` also requires a working `openresty` binary on `PATH`.
`OPHAL_SMOKE_KEEP=1` leaves the generated tree, databases and error logs behind
instead of deleting them, which is most of the evidence when something fails.
