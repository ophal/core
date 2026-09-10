#!/usr/bin/env bash
#
# Measures what a password digest costs, and asserts the two implementations
# agree before either replaces the other.
#
#   bash tests/bench/run_digest_bench.sh
#
# Runs under `resty`, which is the only runtime Ophal supports. The pure-Lua
# SHA-256 is no longer part of Ophal -- this is the measurement that retired it,
# kept because the reasoning is only checkable against both implementations.
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)

export LUA_PATH="$ROOT/?.lua;$ROOT/?/init.lua;;"

cd "$ROOT"
exec resty tests/bench/digest_bench.lua
