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

#[[ The suite runs under `resty`, which is LuaJIT with OpenResty's libraries.
#
# It ran under `lua5.1` until 2026-09-10, which meant every assertion in it was
# a statement about a VM Ophal does not run on. The two differ in ways that
# reach this codebase: PUC Lua accepts unknown string escapes that LuaJIT
# rejects, `pairs` visits keys in a different order, and `tostring` on a number
# formats differently. Two tests were passing only under PUC when the move was
# made, and one of them -- `ident_left_out_of_the_order` -- was pinned to
# PUC's `pairs` order over a two-key table and asserted the wrong one of two
# possible errors.

resty "$ROOT/tests/unit/test_module_order.lua"
resty "$ROOT/tests/unit/test_entity_contract.lua"
resty "$ROOT/tests/unit/test_request_reset.lua"
resty "$ROOT/tests/unit/test_cache.lua"
resty "$ROOT/tests/unit/test_database_result.lua"
resty "$ROOT/tests/unit/test_database_driver_lsqlite3.lua"
resty "$ROOT/tests/unit/test_query_layer.lua"
resty "$ROOT/tests/unit/test_sql_surface.lua"
resty "$ROOT/tests/unit/test_json.lua"
resty "$ROOT/tests/unit/test_random.lua"
resty "$ROOT/tests/unit/test_theme_escaping.lua"
resty "$ROOT/tests/unit/test_cookie_security.lua"
resty "$ROOT/tests/unit/test_csrf.lua"
resty "$ROOT/tests/unit/test_fs_stats.lua"
resty "$ROOT/tests/unit/test_session.lua"
resty "$ROOT/tests/unit/test_http_cache.lua"
resty "$ROOT/tests/unit/test_file_post_process.lua"
resty "$ROOT/tests/unit/test_text.lua"
resty "$ROOT/tests/unit/test_util.lua"
resty "$ROOT/tests/unit/test_fs_path.lua"
resty "$ROOT/tests/unit/test_digest.lua"
resty "$ROOT/tests/unit/test_password_hashing.lua"
resty "$ROOT/tests/unit/test_logging.lua"
resty "$ROOT/tests/unit/test_cli.lua"
resty "$ROOT/tests/unit/test_install.lua"
resty "$ROOT/tests/unit/test_migrate.lua"
resty "$ROOT/tests/unit/test_projection_runtime.lua"
resty "$ROOT/tests/unit/test_jobs.lua"
resty "$ROOT/tests/unit/test_user_permissions.lua"
resty "$ROOT/tests/unit/test_escaping.lua"
resty "$ROOT/tests/unit/test_runtime_fs.lua"
resty "$ROOT/tests/unit/test_settings_loader.lua"
resty "$ROOT/tests/unit/test_pager.lua"

printf 'all unit tests passed\n'
