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
VENDOR_LUA_PATH="$VENDOR_ROOT/?.lua;$VENDOR_ROOT/?/init.lua;$VENDOR_LUA_SHARE/?.lua;$VENDOR_LUA_SHARE/?/init.lua;;"
VENDOR_LUA_CPATH=';;'
if [[ -n "$VENDOR_LUA_LIB_DIR" ]]; then
  VENDOR_LUA_CPATH="$VENDOR_LUA_LIB_DIR/?.so;;"
fi
SMOKE_TMP=$(mktemp -d)
LAST_OUTPUT=''
LAST_STATUS=0
LAST_SCENARIO=''

cleanup() {
  rm -rf "$SMOKE_TMP"
}
trap cleanup EXIT

check_dependencies() {
  local output_file status output
  local -a dep_env

  output_file=$(mktemp)
  dep_env=(
    "LUA_PATH=$VENDOR_LUA_PATH"
    "LUA_CPATH=$VENDOR_LUA_CPATH"
  )
  if [[ -n "$VENDOR_LD_LIB_DIR" ]]; then
    dep_env=("LD_LIBRARY_PATH=$VENDOR_LD_LIB_DIR${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" "${dep_env[@]}")
  fi

  set +e
  env -i "${dep_env[@]}" lua5.1 - <<'LUA' >"$output_file" 2>&1
local missing = {}
for _, name in ipairs({'lfs', 'lpeg', 'uuid', 'socket', 'seawolf', 'dkjson'}) do
  local ok = pcall(require, name)
  if not ok then
    missing[#missing + 1] = name
  end
end
if #missing > 0 then
  io.write(table.concat(missing, "\n"))
  os.exit(1)
end
LUA
  status=$?
  set -e
  output=$(cat "$output_file")
  rm -f "$output_file"

  if [[ $status -ne 0 ]]; then
    LAST_SCENARIO='dependency_preflight'
    LAST_STATUS=$status
    LAST_OUTPUT=$output
    fail 'missing Lua runtime dependencies required for CGI smoke execution; run: bash tests/smoke/setup_vendor_runtime.sh'
  fi
}

prepare_tree() {
  mkdir -p "$SMOKE_TMP/files" "$SMOKE_TMP/sessions"
  ln -s "$ROOT/includes" "$SMOKE_TMP/includes"
  ln -s "$ROOT/modules" "$SMOKE_TMP/modules"
  ln -s "$ROOT/themes" "$SMOKE_TMP/themes"
  ln -s "$ROOT/libraries" "$SMOKE_TMP/libraries"
  ln -s "$ROOT/index.cgi" "$SMOKE_TMP/index.cgi"
  ln -s "$ROOT/cron.cgi" "$SMOKE_TMP/cron.cgi"

  cat > "$SMOKE_TMP/settings.lua" <<'LUA'
return function(settings, vault)
  local getenv = os.getenv
  local scenario = getenv('OPHAL_SMOKE_SCENARIO') or ''
  local tmp_root = getenv('OPHAL_SMOKE_TMP') or '.'

  settings.version = {
    core = true,
    number = true,
    revision = false,
  }
  settings.language = 'en'
  settings.language_dir = 'ltr'
  settings.site = {
    frontpage = 'lorem_ipsum',
    name = 'Ophal Smoke',
    hash = (vault.site or {}).hash or 'ophal-smoke-hash',
    logo_title = 'The Ophal Project',
    logo_path = 'images/ophalproject.png',
    files_path = 'files',
  }
  settings.micro_cache = false
  settings.debugapi = false
  settings.maintenance_mode = false
  settings.output_buffering = (scenario == 'output_buffering')
  settings.sessionapi = {
    enabled = true,
    ttl = 86400,
    lock_ttl = 120,
    path = tmp_root .. '/sessions',
  }
  settings.formapi = false
  settings.date_format = '!%Y-%m-%d %H:%M UTC'
  settings.route_aliases_storage = false
  settings.route_aliases_prepend_language = false
  settings.route_redirects_storage = false
  settings.route_redirects_prepend_language = false
  settings.modules = {
    lorem_ipsum = true,
  }
  settings.db = nil
  settings.theme = {
    name = 'basic',
  }
end
LUA

  cat > "$SMOKE_TMP/vault.lua" <<'LUA'
return {
  site = {
    hash = 'ophal-smoke-hash',
  },
}
LUA
}

fail() {
  printf 'FAIL: %s
' "$1" >&2
  if [[ -n "$LAST_SCENARIO" ]]; then
    printf 'Scenario: %s
' "$LAST_SCENARIO" >&2
  fi
  if [[ -n "$LAST_OUTPUT" ]]; then
    printf '%s
' '--- output ---' >&2
    printf '%s
' "$LAST_OUTPUT" >&2
    printf '%s
' '-------------' >&2
  fi
  exit 1
}

assert_status_zero() {
  [[ "$LAST_STATUS" -eq 0 ]] || fail "expected zero exit status"
}

assert_contains() {
  local needle=$1
  printf '%s' "$LAST_OUTPUT" | grep -Fq -- "$needle" || fail "missing expected text: $needle"
}

assert_regex() {
  local pattern=$1
  printf '%s' "$LAST_OUTPUT" | grep -Eqi -- "$pattern" || fail "missing expected pattern: $pattern"
}

run_scenario() {
  local name=$1
  local body=$2
  local -a run_env
  shift 2

  run_env=(
    "PATH=$PATH"
    "HOME=${HOME:-/tmp}"
    "OPHAL_SMOKE_ROOT=$ROOT"
    "OPHAL_SMOKE_TMP=$SMOKE_TMP"
    "OPHAL_SMOKE_SCENARIO=$name"
    "LUA_PATH=$VENDOR_LUA_PATH"
    "LUA_CPATH=$VENDOR_LUA_CPATH"
  )
  if [[ -n "$VENDOR_LD_LIB_DIR" ]]; then
    run_env+=("LD_LIBRARY_PATH=$VENDOR_LD_LIB_DIR${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}")
  elif [[ -n ${LD_LIBRARY_PATH-} ]]; then
    run_env+=("LD_LIBRARY_PATH=$LD_LIBRARY_PATH")
  fi

  LAST_SCENARIO=$name
  set +e
  if [[ -n "$body" ]]; then
    LAST_OUTPUT=$(cd "$SMOKE_TMP" && printf '%s' "$body" | env -i "${run_env[@]}" "$@" lua5.1 "$ROOT/tests/smoke/cgi_runner.lua" "$name" 2>&1)
    LAST_STATUS=$?
  else
    LAST_OUTPUT=$(cd "$SMOKE_TMP" && env -i "${run_env[@]}" "$@" lua5.1 "$ROOT/tests/smoke/cgi_runner.lua" "$name" 2>&1)
    LAST_STATUS=$?
  fi
  set -e
}

report_ok() {
  printf 'ok %s
' "$1"
}

check_dependencies
prepare_tree

run_scenario index_frontpage ''   REQUEST_METHOD=GET SCRIPT_NAME=/index.cgi REQUEST_URI=/ QUERY_STRING= HTTP_HOST=example.com SERVER_NAME=example.com
assert_status_zero
assert_regex '^content-type: text/html; charset=utf-8'
assert_regex '^x-frame-options: SAMEORIGIN'
assert_contains 'Lorem Ipsum'
report_ok index_frontpage

run_scenario index_alias_route ''   REQUEST_METHOD=GET SCRIPT_NAME=/index.cgi REQUEST_URI=/loremipsum QUERY_STRING= HTTP_HOST=example.com SERVER_NAME=example.com
assert_status_zero
assert_contains 'Lorem Ipsum'
report_ok index_alias_route

run_scenario index_prefixed_path_and_query ''   REQUEST_METHOD=GET SCRIPT_NAME=/index.cgi REQUEST_URI='/index.cgi/lorem_ipsum?foo=bar' QUERY_STRING='foo=bar' HTTP_HOST=example.com SERVER_NAME=example.com
assert_status_zero
assert_contains 'Lorem Ipsum'
report_ok index_prefixed_path_and_query

run_scenario not_found ''   REQUEST_METHOD=GET SCRIPT_NAME=/index.cgi REQUEST_URI=/does-not-exist QUERY_STRING= HTTP_HOST=example.com SERVER_NAME=example.com
assert_status_zero
assert_regex '^status: 404'
assert_contains 'The requested page could not be found.'
report_ok not_found

run_scenario request_metadata ''   REQUEST_METHOD=GET SCRIPT_NAME=/index.cgi REQUEST_URI='/index.cgi/lorem_ipsum?foo=bar' QUERY_STRING='foo=bar' HTTP_HOST=example.com SERVER_NAME=example.com
assert_status_zero
assert_contains 'SMOKE_URI=/index.cgi/lorem_ipsum?foo=bar'
assert_contains 'SMOKE_URI_NO_QUERY=/index.cgi/lorem_ipsum'
assert_contains 'SMOKE_PATH=lorem_ipsum'
assert_contains 'SMOKE_QUERY_FOO=bar'
report_ok request_metadata

run_scenario request_body_get ''   REQUEST_METHOD=GET SCRIPT_NAME=/index.cgi REQUEST_URI=/body-check QUERY_STRING= HTTP_HOST=example.com SERVER_NAME=example.com
assert_status_zero
assert_contains 'SMOKE_BODY_IS_NIL=true'
report_ok request_body_get

run_scenario request_body_post 'alpha=1&beta=2'   REQUEST_METHOD=POST CONTENT_LENGTH=14 CONTENT_TYPE='application/x-www-form-urlencoded' SCRIPT_NAME=/index.cgi REQUEST_URI=/body-check QUERY_STRING= HTTP_HOST=example.com SERVER_NAME=example.com
assert_status_zero
assert_contains 'SMOKE_BODY=alpha=1&beta=2'
report_ok request_body_post

run_scenario redirect_goto ''   REQUEST_METHOD=GET SCRIPT_NAME=/index.cgi REQUEST_URI=/redirect-check QUERY_STRING= HTTP_HOST=example.com SERVER_NAME=example.com
assert_status_zero
assert_regex '^status: 302'
assert_regex '^location: http://example\.com/loremipsum'
report_ok redirect_goto

run_scenario cookie_append ''   REQUEST_METHOD=GET SCRIPT_NAME=/index.cgi REQUEST_URI=/cookie-check QUERY_STRING= HTTP_HOST=example.com SERVER_NAME=example.com
assert_status_zero
assert_regex '^set-cookie: alpha=1;'
assert_regex '^set-cookie: beta=2;'
assert_contains 'SMOKE_COOKIE_APPEND=ok'
report_ok cookie_append

run_scenario output_buffering ''   REQUEST_METHOD=GET SCRIPT_NAME=/index.cgi REQUEST_URI=/buffer-check QUERY_STRING= HTTP_HOST=example.com SERVER_NAME=example.com
assert_status_zero
assert_regex '^x-smoke: buffered'
assert_contains 'SMOKE_BUFFERED_OUTPUT=ok'
report_ok output_buffering

run_scenario cron_smoke ''   REQUEST_METHOD=GET SCRIPT_NAME=/cron.cgi REQUEST_URI=/cron.cgi QUERY_STRING= HTTP_HOST=example.com SERVER_NAME=example.com
assert_status_zero
assert_regex '^content-type: text/html; charset=utf-8'
assert_regex '^x-frame-options: SAMEORIGIN'
report_ok cron_smoke

printf 'all smoke scenarios passed
'
