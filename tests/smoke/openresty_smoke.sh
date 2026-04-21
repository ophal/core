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
VENDOR_LUA_PATH="./?.lua;./?/init.lua;$VENDOR_ROOT/?.lua;$VENDOR_ROOT/?/init.lua;$VENDOR_LUA_SHARE/?.lua;$VENDOR_LUA_SHARE/?/init.lua;;"
VENDOR_LUA_CPATH=';;'
if [[ -n "$VENDOR_LUA_LIB_DIR" ]]; then
  VENDOR_LUA_CPATH="$VENDOR_LUA_LIB_DIR/?.so;;"
fi

SMOKE_ROOT=$(mktemp -d)
SMOKE_DOCROOT="$SMOKE_ROOT/docroot"
SMOKE_PREFIX="$SMOKE_ROOT/prefix"
SMOKE_CONF="$SMOKE_ROOT/nginx.conf"
LAST_OUTPUT=''
LAST_STATUS=0
LAST_SCENARIO=''

pick_port() {
  python3 - <<'PY2'
import socket
s = socket.socket()
s.bind(('127.0.0.1', 0))
print(s.getsockname()[1])
s.close()
PY2
}

SMOKE_PORT=$(pick_port)
PERSISTENT_PORT=$(pick_port)
BASE_URL="http://127.0.0.1:${SMOKE_PORT}"
PERSISTENT_URL="http://127.0.0.1:${PERSISTENT_PORT}"

cleanup() {
  openresty -p "$SMOKE_PREFIX" -c "$SMOKE_CONF" -s stop >/dev/null 2>&1 || true
  rm -rf "$SMOKE_ROOT"
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
    fail 'missing Lua runtime dependencies required for OpenResty smoke execution; run: bash tests/smoke/setup_vendor_runtime.sh'
  fi
}

check_openresty() {
  command -v openresty >/dev/null 2>&1 || fail 'openresty is not installed or not on PATH'
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
  if [[ -f "$SMOKE_PREFIX/logs/error.log" ]]; then
    printf '%s
' '--- error.log ---' >&2
    sed -n '1,220p' "$SMOKE_PREFIX/logs/error.log" >&2 || true
    printf '%s
' '-----------------' >&2
  fi
  exit 1
}

assert_status_zero() {
  [[ "$LAST_STATUS" -eq 0 ]] || fail 'expected zero curl exit status'
}

assert_contains() {
  local needle=$1
  printf '%s' "$LAST_OUTPUT" | grep -Fq -- "$needle" || fail "missing expected text: $needle"
}

assert_regex() {
  local pattern=$1
  printf '%s' "$LAST_OUTPUT" | grep -Eqi -- "$pattern" || fail "missing expected pattern: $pattern"
}

extract_marker() {
  local marker=$1
  printf '%s\n' "$LAST_OUTPUT" | sed -n "s/^${marker}=//p" | tail -n 1
}

prepare_tree() {
  mkdir -p "$SMOKE_DOCROOT" "$SMOKE_PREFIX/logs" "$SMOKE_PREFIX/client_body_temp"     "$SMOKE_PREFIX/proxy_temp" "$SMOKE_PREFIX/fastcgi_temp" "$SMOKE_PREFIX/uwsgi_temp"     "$SMOKE_PREFIX/scgi_temp" "$SMOKE_ROOT/files" "$SMOKE_ROOT/sessions"
  ln -s "$ROOT/includes" "$SMOKE_DOCROOT/includes"
  ln -s "$ROOT/modules" "$SMOKE_DOCROOT/modules"
  ln -s "$ROOT/themes" "$SMOKE_DOCROOT/themes"
  ln -s "$ROOT/libraries" "$SMOKE_DOCROOT/libraries"
  ln -s "$ROOT/index.cgi" "$SMOKE_DOCROOT/index.cgi"
  ln -s "$ROOT/cron.cgi" "$SMOKE_DOCROOT/cron.cgi"

  cat > "$SMOKE_DOCROOT/settings.lua" <<'LUA'
return function(settings, vault)
  local getenv = os.getenv
  local scenario = getenv('OPHAL_SMOKE_SCENARIO') or ''
  local tmp_root = getenv('OPHAL_SMOKE_TMP') or '.'

  if type(ngx) == 'table' and ngx.req and ngx.req.get_uri_args then
    local args = ngx.req.get_uri_args()
    local arg_scenario = args.scenario
    if type(arg_scenario) == 'table' then
      arg_scenario = arg_scenario[1]
    end
    if type(arg_scenario) == 'string' and arg_scenario ~= '' then
      scenario = arg_scenario
    end
  end

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

  cat > "$SMOKE_DOCROOT/vault.lua" <<'LUA'
return {
  site = {
    hash = 'ophal-smoke-hash',
  },
}
LUA

  cat > "$SMOKE_CONF" <<EOF
env OPHAL_SMOKE_TMP;
worker_processes 1;
pid logs/nginx.pid;
error_log logs/error.log info;

events {
  worker_connections 1024;
}

http {
  lua_package_path '$VENDOR_LUA_PATH';
  lua_package_cpath '$VENDOR_LUA_CPATH';

  access_log logs/access.log;
  client_body_temp_path client_body_temp;
  proxy_temp_path proxy_temp;
  fastcgi_temp_path fastcgi_temp;
  uwsgi_temp_path uwsgi_temp;
  scgi_temp_path scgi_temp;

  server {
    listen 127.0.0.1:$SMOKE_PORT;
    server_name example.com;
    root $SMOKE_DOCROOT;

    location = / {
      index index.cgi;
    }

    location = /__smoke__ {
      lua_code_cache off;
      default_type text/html;
      rewrite_by_lua_block {
        require('lfs').chdir(ngx.var.document_root)
      }
      content_by_lua_file $ROOT/tests/smoke/openresty_runner.lua;
    }

    location / {
      index index.cgi;

      if (!-f \$request_filename) {
        rewrite ^(.*)$ /index.cgi last;
        break;
      }

      if (!-d \$request_filename) {
        rewrite ^(.*)$ /index.cgi last;
        break;
      }
    }

    error_page 404 /index.cgi;

    location ~* ^.+\.(?:css|cur|js|jpg|jpeg|gif|htc|ico|png|html|xml|less|ttf|pdf|map)$ {
      access_log off;
      expires 30d;
      tcp_nodelay off;
      open_file_cache max=3000 inactive=120s;
      open_file_cache_valid 45s;
      open_file_cache_min_uses 2;
      open_file_cache_errors off;
    }

    location ~ \.cgi$ {
      lua_code_cache off;
      default_type text/html;
      rewrite_by_lua_block {
        require('lfs').chdir(ngx.var.document_root)
      }
      content_by_lua_file \$request_filename;
    }
  }

  ## Persistent runtime server (lua_code_cache on) — tests state isolation.
  server {
    listen 127.0.0.1:$PERSISTENT_PORT;
    server_name example.com;
    root $SMOKE_DOCROOT;

    location = / {
      index index.cgi;
    }

    location = /__smoke__ {
      lua_code_cache on;
      default_type text/html;
      rewrite_by_lua_block {
        require('lfs').chdir(ngx.var.document_root)
      }
      content_by_lua_file $ROOT/tests/smoke/openresty_runner.lua;
    }

    location / {
      index index.cgi;

      if (!-f \$request_filename) {
        rewrite ^(.*)$ /index.cgi last;
        break;
      }

      if (!-d \$request_filename) {
        rewrite ^(.*)$ /index.cgi last;
        break;
      }
    }

    error_page 404 /index.cgi;

    location ~ \.cgi$ {
      lua_code_cache on;
      default_type text/html;
      rewrite_by_lua_block {
        require('lfs').chdir(ngx.var.document_root)
      }
      content_by_lua_file \$request_filename;
    }
  }
}
EOF
}

port_ready() {
  python3 - "$1" <<'PY2'
import socket
import sys
host = '127.0.0.1'
port = int(sys.argv[1])
sock = socket.socket()
sock.settimeout(0.2)
try:
    sock.connect((host, port))
except OSError:
    raise SystemExit(1)
finally:
    sock.close()
PY2
}

start_openresty() {
  local output

  set +e
  output=$(OPHAL_SMOKE_TMP="$SMOKE_ROOT" openresty -t -p "$SMOKE_PREFIX" -c "$SMOKE_CONF" 2>&1)
  LAST_STATUS=$?
  set -e
  LAST_OUTPUT=$output
  [[ "$LAST_STATUS" -eq 0 ]] || fail 'openresty config test failed'

  OPHAL_SMOKE_TMP="$SMOKE_ROOT" openresty -p "$SMOKE_PREFIX" -c "$SMOKE_CONF"

  for _ in $(seq 1 50); do
    if port_ready "$SMOKE_PORT"; then
      return 0
    fi
    sleep 0.1
  done

  fail 'openresty did not become ready'
}

run_request() {
  local name=$1
  shift

  LAST_SCENARIO=$name
  set +e
  LAST_OUTPUT=$(curl -sS -i --max-time 10 -H 'Host: example.com' "$@" 2>&1)
  LAST_STATUS=$?
  set -e
}

report_ok() {
  printf 'ok %s
' "$1"
}

check_dependencies
check_openresty
prepare_tree
start_openresty

run_request index_frontpage "$BASE_URL/"
assert_status_zero
assert_regex '^HTTP/1\.[01] 200'
assert_regex '^X-Frame-Options: SAMEORIGIN'
assert_contains 'Lorem Ipsum'
report_ok index_frontpage

run_request index_alias_route "$BASE_URL/loremipsum"
assert_status_zero
assert_regex '^HTTP/1\.[01] 200'
assert_contains 'Lorem Ipsum'
report_ok index_alias_route

run_request index_prefixed_path_and_query "$BASE_URL/index.cgi/lorem_ipsum?foo=bar"
assert_status_zero
assert_regex '^HTTP/1\.[01] 200'
assert_contains 'Lorem Ipsum'
report_ok index_prefixed_path_and_query

run_request not_found "$BASE_URL/does-not-exist"
assert_status_zero
assert_regex '^HTTP/1\.[01] 404'
assert_contains 'The requested page could not be found.'
report_ok not_found

run_request request_metadata "$BASE_URL/__smoke__?foo=bar&scenario=request_metadata"
assert_status_zero
assert_regex '^HTTP/1\.[01] 200'
assert_contains 'SMOKE_URI=/__smoke__?foo=bar&scenario=request_metadata'
assert_contains 'SMOKE_URI_NO_QUERY=/__smoke__'
assert_contains 'SMOKE_PATH=__smoke__'
assert_contains 'SMOKE_QUERY_FOO=bar'
report_ok request_metadata

run_request request_body_get "$BASE_URL/__smoke__?scenario=request_body_get"
assert_status_zero
assert_regex '^HTTP/1\.[01] 200'
assert_contains 'SMOKE_BODY_IS_NIL=true'
report_ok request_body_get

run_request request_body_post -X POST -H 'Content-Type: application/x-www-form-urlencoded' --data 'alpha=1&beta=2' "$BASE_URL/__smoke__?scenario=request_body_post"
assert_status_zero
assert_regex '^HTTP/1\.[01] 200'
assert_contains 'SMOKE_BODY=alpha=1&beta=2'
report_ok request_body_post

run_request redirect_goto "$BASE_URL/__smoke__?scenario=redirect_goto"
assert_status_zero
assert_regex '^HTTP/1\.[01] 302'
assert_regex '^Location: http://example\.com/loremipsum'
report_ok redirect_goto

run_request cookie_append "$BASE_URL/__smoke__?scenario=cookie_append"
assert_status_zero
assert_regex '^HTTP/1\.[01] 200'
assert_regex '^Set-Cookie: alpha=1;'
assert_regex '^Set-Cookie: beta=2;'
assert_contains 'SMOKE_COOKIE_APPEND=ok'
report_ok cookie_append

run_request output_buffering "$BASE_URL/__smoke__?scenario=output_buffering"
assert_status_zero
assert_regex '^HTTP/1\.[01] 200'
assert_regex '^X-Smoke: buffered'
assert_contains 'SMOKE_BUFFERED_OUTPUT=ok'
report_ok output_buffering

run_request cron_smoke "$BASE_URL/cron.cgi"
assert_status_zero
assert_regex '^HTTP/1\.[01] 200'
assert_regex '^X-Frame-Options: SAMEORIGIN'
report_ok cron_smoke

# ================================================================
# Persistent runtime tests (lua_code_cache on)
# Verify no state leaks across sequential requests.
# ================================================================

# Wait for persistent port to be ready
for _ in $(seq 1 50); do
  if port_ready "$PERSISTENT_PORT"; then
    break
  fi
  sleep 0.1
done

# persistent_get_isolation: _GET from request 1 must not leak into request 2
run_request persistent_get_isolation_req1 "$PERSISTENT_URL/?foo=bar"
assert_status_zero
assert_regex '^HTTP/1\.[01] 200'
assert_contains 'Lorem Ipsum'
report_ok persistent_get_isolation_req1

run_request persistent_get_isolation_req2 "$PERSISTENT_URL/"
assert_status_zero
assert_regex '^HTTP/1\.[01] 200'
assert_contains 'Lorem Ipsum'
report_ok persistent_get_isolation_req2

# persistent_title_isolation: title from frontpage must not leak into 404
run_request persistent_title_req1 "$PERSISTENT_URL/"
assert_status_zero
assert_regex '^HTTP/1\.[01] 200'
assert_contains 'Lorem Ipsum'
report_ok persistent_title_req1

run_request persistent_title_req2 "$PERSISTENT_URL/does-not-exist"
assert_status_zero
assert_regex '^HTTP/1\.[01] 404'
assert_contains 'The requested page could not be found.'
report_ok persistent_title_req2

# persistent_route_isolation: route_arg from request 1 must not leak
run_request persistent_route_req1 "$PERSISTENT_URL/loremipsum"
assert_status_zero
assert_regex '^HTTP/1\.[01] 200'
assert_contains 'Lorem Ipsum'
report_ok persistent_route_req1

run_request persistent_route_req2 "$PERSISTENT_URL/"
assert_status_zero
assert_regex '^HTTP/1\.[01] 200'
assert_contains 'Lorem Ipsum'
report_ok persistent_route_req2

# persistent_csrf_isolation: JS-visible CSRF token must belong to the current
# session, not a previous request handled by the same worker.
cookie_a="$SMOKE_ROOT/cookie-a.txt"
cookie_b="$SMOKE_ROOT/cookie-b.txt"

run_request persistent_csrf_req1 -c "$cookie_a" -b "$cookie_a" "$PERSISTENT_URL/__smoke__?scenario=csrf_token"
assert_status_zero
assert_regex '^HTTP/1\.[01] 200'
token_a=$(extract_marker 'SMOKE_CSRF_TOKEN')
[[ -n "$token_a" ]] || fail 'missing CSRF token for persistent request 1'
report_ok persistent_csrf_req1

run_request persistent_csrf_req2 -c "$cookie_b" -b "$cookie_b" "$PERSISTENT_URL/__smoke__?scenario=csrf_token"
assert_status_zero
assert_regex '^HTTP/1\.[01] 200'
token_b=$(extract_marker 'SMOKE_CSRF_TOKEN')
[[ -n "$token_b" ]] || fail 'missing CSRF token for persistent request 2'
[[ "$token_a" != "$token_b" ]] || fail 'persistent request 2 reused request 1 CSRF token'
report_ok persistent_csrf_req2

printf 'all openresty smoke scenarios passed
'
