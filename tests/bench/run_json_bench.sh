#!/usr/bin/env bash
#
# Measures what a JSON backend costs, and asserts where two of them disagree.
#
#   bash tests/smoke/setup_vendor_runtime.sh   # once, for dkjson and seawolf
#   bash tests/bench/run_json_bench.sh
#
# Runs under `resty` because `cjson` ships with OpenResty and is absent from the
# `lua5.1` the CLI names -- which is the split the shim exists to span, so the
# harness has to run where both backends are reachable.
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
VENDOR_ROOT="$ROOT/tests/smoke/vendor"
VENDOR_LUA_SHARE="$VENDOR_ROOT/unpack/usr/share/lua/5.1"

[[ -f "$VENDOR_LUA_SHARE/dkjson.lua" ]] || {
  printf 'dkjson is not vendored; run: bash tests/smoke/setup_vendor_runtime.sh\n' >&2
  exit 1
}

export LUA_PATH="$ROOT/?.lua;$ROOT/?/init.lua;$VENDOR_ROOT/?.lua;$VENDOR_ROOT/?/init.lua;$VENDOR_LUA_SHARE/?.lua;$VENDOR_LUA_SHARE/?/init.lua;;"

cd "$ROOT"
exec resty tests/bench/json_bench.lua
