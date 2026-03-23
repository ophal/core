#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
VENDOR_ROOT="$ROOT/tests/smoke/vendor"
VENDOR_UNPACK="$VENDOR_ROOT/unpack"
VENDOR_LUA_SHARE="$VENDOR_UNPACK/usr/share/lua/5.1"
VENDOR_LUA_LIB_DIR=$(find "$VENDOR_UNPACK/usr/lib" -path '*/lua/5.1' -type d 2>/dev/null | sed -n '1p')
VENDOR_LD_LIB_DIR=''
if [[ -n "$VENDOR_LUA_LIB_DIR" ]]; then
  VENDOR_LD_LIB_DIR=$(cd -- "$VENDOR_LUA_LIB_DIR/../.." && pwd)
fi

export LUA_PATH="$ROOT/?.lua;$ROOT/?/init.lua;$VENDOR_ROOT/?.lua;$VENDOR_ROOT/?/init.lua;$VENDOR_LUA_SHARE/?.lua;$VENDOR_LUA_SHARE/?/init.lua;;"
export LUA_CPATH=';;'
if [[ -n "$VENDOR_LUA_LIB_DIR" ]]; then
  export LUA_CPATH="$VENDOR_LUA_LIB_DIR/?.so;;"
fi
if [[ -n "$VENDOR_LD_LIB_DIR" ]]; then
  export LD_LIBRARY_PATH="$VENDOR_LD_LIB_DIR${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
fi

cd "$ROOT"

lua5.1 "$ROOT/tests/unit/test_module_order.lua"
lua5.1 "$ROOT/tests/unit/test_entity_contract.lua"

printf 'all unit tests passed\n'
