#!/usr/bin/env bash
#
# Runs the query-layer benchmark against the vendored backends.
#
#   bash tests/bench/setup_backends.sh all   # once
#   bash tests/bench/run_bench.sh
#
# Environment: OPHAL_BENCH_ITERATIONS, OPHAL_BENCH_CONCURRENCY,
# OPHAL_BENCH_ROWS, OPHAL_BENCH_PAGE, OPHAL_BENCH_ONLY (substring of a
# candidate id).
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

# The C drivers are built for the PUC Lua 5.1 ABI, which LuaJIT loads
# unchanged -- the same arrangement the smoke suite already uses for
# luadbi-sqlite3.
export LUA_PATH="$ROOT/?.lua;$ROOT/?/init.lua;$LUA_PREFIX/share/?.lua;$LUA_PREFIX/share/?/init.lua;$LUA_PREFIX/usr/share/lua/5.1/?.lua;$LUA_PREFIX/usr/share/lua/5.1/?/init.lua;;"
export LUA_CPATH="$LUA_PREFIX/usr/lib/x86_64-linux-gnu/lua/5.1/?.so;;"
export LD_LIBRARY_PATH="$PG_PREFIX/usr/lib/x86_64-linux-gnu:$PG_PREFIX/usr/lib/postgresql/$PG_MAJOR/lib:$MY_PREFIX/usr/lib/x86_64-linux-gnu:$LUA_PREFIX/usr/lib/x86_64-linux-gnu${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export OPHAL_BENCH_SQLITE="${OPHAL_BENCH_SQLITE:-$BACKENDS/run/bench.sqlite}"

mkdir -p "$(dirname "$OPHAL_BENCH_SQLITE")"
rm -f "$OPHAL_BENCH_SQLITE"

cd "$ROOT"
exec resty tests/bench/bench.lua
