#!/usr/bin/env bash
#
# Runs the layer's driver contract against the vendored backends.
#
#   bash tests/bench/setup_backends.sh all   # once
#   bash tests/bench/run_driver_contract.sh
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
BACKENDS="$ROOT/tests/smoke/vendor/backends"
PG_PREFIX="$BACKENDS/pg"
MY_PREFIX="$BACKENDS/mysql"
LUA_PREFIX="$BACKENDS/lua"
PG_MAJOR="${OPHAL_BENCH_PG_MAJOR:-16}"

[[ -d "$LUA_PREFIX" ]] || {
  printf 'backends are not installed; run: bash tests/bench/setup_backends.sh all\n' >&2
  exit 1
}

export LUA_PATH="$ROOT/?.lua;$ROOT/?/init.lua;$LUA_PREFIX/share/?.lua;$LUA_PREFIX/share/?/init.lua;$LUA_PREFIX/usr/share/lua/5.1/?.lua;$LUA_PREFIX/usr/share/lua/5.1/?/init.lua;;"
export LUA_CPATH="$LUA_PREFIX/usr/lib/x86_64-linux-gnu/lua/5.1/?.so;;"
export LD_LIBRARY_PATH="$PG_PREFIX/usr/lib/x86_64-linux-gnu:$PG_PREFIX/usr/lib/postgresql/$PG_MAJOR/lib:$MY_PREFIX/usr/lib/x86_64-linux-gnu:$LUA_PREFIX/usr/lib/x86_64-linux-gnu${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export OPHAL_BENCH_SQLITE="${OPHAL_BENCH_SQLITE:-$BACKENDS/run/contract.sqlite}"

mkdir -p "$(dirname "$OPHAL_BENCH_SQLITE")"
# The write-ahead log and its shared-memory index are separate files, and a
# stale one left beside a deleted database is not a fresh database.
rm -f "$OPHAL_BENCH_SQLITE" "$OPHAL_BENCH_SQLITE"-wal "$OPHAL_BENCH_SQLITE"-shm
rm -f "$OPHAL_BENCH_SQLITE".ls "$OPHAL_BENCH_SQLITE".ls-wal "$OPHAL_BENCH_SQLITE".ls-shm

cd "$ROOT"
exec resty tests/bench/injection_probe.lua
