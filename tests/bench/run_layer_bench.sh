#!/usr/bin/env bash
#
# Measures what the query layer costs against calling the driver directly.
#
#   bash tests/bench/setup_backends.sh all   # once
#   bash tests/bench/run_layer_bench.sh
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
BACKENDS="$ROOT/tests/smoke/vendor/backends"
LUA_PREFIX="$BACKENDS/lua"

[[ -d "$LUA_PREFIX" ]] || {
  printf 'backends are not installed; run: bash tests/bench/setup_backends.sh all\n' >&2
  exit 1
}

export LUA_PATH="$ROOT/?.lua;$ROOT/?/init.lua;$LUA_PREFIX/share/?.lua;$LUA_PREFIX/share/?/init.lua;$LUA_PREFIX/usr/share/lua/5.1/?.lua;$LUA_PREFIX/usr/share/lua/5.1/?/init.lua;;"
export LUA_CPATH="$LUA_PREFIX/usr/lib/x86_64-linux-gnu/lua/5.1/?.so;;"

cd "$ROOT"
# resty caps connections at 64 by default, and this holds two backends' pools
# open at once -- 50 PostgreSQL keepalives plus 50 MySQL exceeds it, and the
# overflow surfaces as "operation now in progress" at connect rather than as
# anything naming a limit.
exec resty -c 512 tests/bench/layer_bench.lua
