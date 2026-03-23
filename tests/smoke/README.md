# Smoke Harness

These smoke tests validate the runtime-adapter slice under both CGI and
OpenResty without depending on the workspace `settings.lua`.

## Local Runtime Setup

The harnesses expect a local vendor runtime under `tests/smoke/vendor/`.
That directory is intentionally ignored by git.

Build it with:

```sh
bash tests/smoke/setup_vendor_runtime.sh
```

The setup script downloads and unpacks the packaged Lua modules used by the
harnesses, vendors a fresh `seawolf` checkout, and writes the local `uuid.lua`
shim used by session startup.

Requirements:

- `apt`
- `dpkg-deb`
- `git`
- network access

## Run

```sh
bash tests/smoke/cgi_smoke.sh
bash tests/smoke/openresty_smoke.sh
```

`openresty_smoke.sh` also requires a working `openresty` binary on `PATH`.
