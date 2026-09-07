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
# The database profile runs as a second OpenResty instance rather than another
# server block in the first. Routes are cached per worker after the first
# request, so a worker that has served the module-less profile would answer a
# content request from a route table built without the content module. A
# separate instance is also what makes the warm measurement meaningful: its
# worker only ever serves this profile, so its caches fill the way a real
# site's do.
SMOKE_DB_DOCROOT="$SMOKE_ROOT/db-docroot"
SMOKE_DB_PREFIX="$SMOKE_ROOT/db-prefix"
SMOKE_DB_CONF="$SMOKE_ROOT/nginx-db.conf"
SMOKE_DB_FILE="$SMOKE_ROOT/ophal-smoke.sqlite3"
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
SMOKE_DB_PORT=$(pick_port)
BASE_URL="http://127.0.0.1:${SMOKE_PORT}"
PERSISTENT_URL="http://127.0.0.1:${PERSISTENT_PORT}"
DB_URL="http://127.0.0.1:${SMOKE_DB_PORT}"

# `OPHAL_SMOKE_KEEP=1` leaves the tree behind. A failure otherwise takes the
# database, the generated configuration and both error logs with it, which is
# most of the evidence for anything that goes wrong in the database profile.
cleanup() {
  openresty -p "$SMOKE_PREFIX" -c "$SMOKE_CONF" -s stop >/dev/null 2>&1 || true
  openresty -p "$SMOKE_DB_PREFIX" -c "$SMOKE_DB_CONF" -s stop >/dev/null 2>&1 || true

  if [[ -n "${OPHAL_SMOKE_KEEP:-}" ]]; then
    printf 'kept: %s\n' "$SMOKE_ROOT" >&2
  else
    rm -rf "$SMOKE_ROOT"
  fi
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
for _, name in ipairs({'lfs', 'lpeg', 'uuid', 'seawolf', 'dkjson', 'DBI', 'dbd.sqlite3'}) do
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

# Everything a docroot shares with the checkout. Themes are left out because
# the database profile builds its own; see prepare_db_tree.
link_docroot() {
  local docroot=$1

  ln -s "$ROOT/includes" "$docroot/includes"
  ln -s "$ROOT/modules" "$docroot/modules"
  ln -s "$ROOT/libraries" "$docroot/libraries"
  ln -s "$ROOT/index.lua" "$docroot/index.lua"
  ln -s "$ROOT/cron.lua" "$docroot/cron.lua"
}

prepare_tree() {
  mkdir -p "$SMOKE_DOCROOT" "$SMOKE_PREFIX/logs" "$SMOKE_PREFIX/client_body_temp"     "$SMOKE_PREFIX/proxy_temp" "$SMOKE_PREFIX/fastcgi_temp" "$SMOKE_PREFIX/uwsgi_temp"     "$SMOKE_PREFIX/scgi_temp" "$SMOKE_ROOT/files" "$SMOKE_ROOT/sessions"
  link_docroot "$SMOKE_DOCROOT"
  ln -s "$ROOT/themes" "$SMOKE_DOCROOT/themes"

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
    files_path = tmp_root .. '/files',
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
  if scenario == 'file_upload_chunk' or scenario == 'file_merge_chunks' then
    settings.modules.file = true
    settings.file = {
      filedb_storage = false,
    }
  end
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

  lua_shared_dict ophal_projection_versions 1m;

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

    location = /cron {
      lua_code_cache off;
      default_type text/html;
      set \$ophal_script_name /cron.lua;
      rewrite_by_lua_block {
        require('lfs').chdir(ngx.var.document_root)
      }
      content_by_lua_file \$document_root/cron.lua;
    }

    location = /__smoke__ {
      lua_code_cache off;
      default_type text/html;
      set \$ophal_script_name /index.lua;
      rewrite_by_lua_block {
        require('lfs').chdir(ngx.var.document_root)
      }
      content_by_lua_file $ROOT/tests/smoke/openresty_runner.lua;
    }

    location = /__ophal_index__ {
      internal;
      lua_code_cache off;
      default_type text/html;
      set \$ophal_script_name /index.lua;
      rewrite_by_lua_block {
        require('lfs').chdir(ngx.var.document_root)
      }
      content_by_lua_file \$document_root/index.lua;
    }

    location = /index.lua { return 404; }
    location = /cron.lua { return 404; }
    location = /settings.lua { return 404; }
    location = /vault.lua { return 404; }
    location ^~ /settings/ { return 404; }
    location ^~ /includes/ { return 404; }
    location ^~ /modules/ { return 404; }

    location ~ \.lua$ {
      return 404;
    }

    location ~* ^.+\.(?:css|cur|js|jpg|jpeg|gif|htc|ico|png|html|xml|less|ttf|pdf|map)$ {
      try_files \$uri =404;
      access_log off;
      expires 30d;
      tcp_nodelay off;
      open_file_cache max=3000 inactive=120s;
      open_file_cache_valid 45s;
      open_file_cache_min_uses 2;
      open_file_cache_errors off;
    }

    location / {
      try_files \$uri /__ophal_index__;
    }
  }

  ## Persistent runtime server (lua_code_cache on) — tests state isolation.
  server {
    listen 127.0.0.1:$PERSISTENT_PORT;
    server_name example.com;
    root $SMOKE_DOCROOT;

    location = /cron {
      lua_code_cache on;
      default_type text/html;
      set \$ophal_script_name /cron.lua;
      rewrite_by_lua_block {
        require('lfs').chdir(ngx.var.document_root)
      }
      content_by_lua_file \$document_root/cron.lua;
    }

    location = /__smoke__ {
      lua_code_cache on;
      default_type text/html;
      set \$ophal_script_name /index.lua;
      rewrite_by_lua_block {
        require('lfs').chdir(ngx.var.document_root)
      }
      content_by_lua_file $ROOT/tests/smoke/openresty_runner.lua;
    }

    location = /__ophal_index__ {
      internal;
      lua_code_cache on;
      default_type text/html;
      set \$ophal_script_name /index.lua;
      rewrite_by_lua_block {
        require('lfs').chdir(ngx.var.document_root)
      }
      content_by_lua_file \$document_root/index.lua;
    }

    location = /index.lua { return 404; }
    location = /cron.lua { return 404; }
    location = /settings.lua { return 404; }
    location = /vault.lua { return 404; }
    location ^~ /settings/ { return 404; }
    location ^~ /includes/ { return 404; }
    location ^~ /modules/ { return 404; }

    location ~ \.lua$ {
      return 404;
    }

    location ~* ^.+\.(?:css|cur|js|jpg|jpeg|gif|htc|ico|png|html|xml|less|ttf|pdf|map)$ {
      try_files \$uri =404;
      access_log off;
      expires 30d;
      tcp_nodelay off;
      open_file_cache max=3000 inactive=120s;
      open_file_cache_valid 45s;
      open_file_cache_min_uses 2;
      open_file_cache_errors off;
    }

    location / {
      try_files \$uri /__ophal_index__;
    }
  }
}
EOF
}

prepare_db_tree() {
  mkdir -p "$SMOKE_DB_DOCROOT" "$SMOKE_DB_PREFIX/logs" "$SMOKE_DB_PREFIX/client_body_temp" \
    "$SMOKE_DB_PREFIX/proxy_temp" "$SMOKE_DB_PREFIX/fastcgi_temp" "$SMOKE_DB_PREFIX/uwsgi_temp" \
    "$SMOKE_DB_PREFIX/scgi_temp" "$SMOKE_ROOT/db-files" "$SMOKE_ROOT/db-sessions"
  link_docroot "$SMOKE_DB_DOCROOT"

  # `theme_render()` resolves templates under themes/<name>/ only, and neither
  # shipped theme carries the content module's templates. A content site has to
  # copy them into its theme, so the profile does exactly that rather than
  # pretending the stock theme can render content.
  mkdir -p "$SMOKE_DB_DOCROOT/themes"
  cp -R "$ROOT/themes/basic" "$SMOKE_DB_DOCROOT/themes/basic"
  cp "$ROOT/modules/content/content_teaser.tpl.html" "$SMOKE_DB_DOCROOT/themes/basic/"
  cp "$ROOT/modules/content/content_page.tpl.html" "$SMOKE_DB_DOCROOT/themes/basic/"

  # This profile has no scenario switch. It is one configuration -- database on,
  # content, user and tag enabled, front page served by the content module --
  # because the whole point of a second instance is that its worker warms up
  # against a single, realistic site rather than a mixture.
  cat > "$SMOKE_DB_DOCROOT/settings.lua" <<'LUA'
return function(settings, vault)
  local getenv = os.getenv
  local tmp_root = getenv('OPHAL_SMOKE_TMP') or '.'
  local db_path = getenv('OPHAL_SMOKE_DB')

  settings.version = {
    core = true,
    number = true,
    revision = false,
  }
  settings.language = 'en'
  settings.language_dir = 'ltr'
  settings.site = {
    frontpage = 'content',
    name = 'Ophal Smoke DB',
    hash = (vault.site or {}).hash or 'ophal-smoke-hash',
    logo_title = 'The Ophal Project',
    logo_path = 'images/ophalproject.png',
    files_path = tmp_root .. '/db-files',
  }
  settings.micro_cache = false
  settings.debugapi = false
  settings.maintenance_mode = false
  settings.output_buffering = false
  settings.sessionapi = {
    enabled = true,
    ttl = 86400,
    lock_ttl = 120,
    path = tmp_root .. '/db-sessions',
  }
  settings.formapi = true
  settings.date_format = '!%Y-%m-%d %H:%M UTC'

  -- Aliases come from storage here, so the route projection is on the measured
  -- path instead of being a code path only the unit tests ever reach.
  settings.route_aliases_storage = true
  settings.route_aliases_prepend_language = false
  settings.route_redirects_storage = false
  settings.route_redirects_prepend_language = false

  settings.modules = {
    content = true,
    user = true,
    tag = true,
  }

  -- Which entity types carry tags is site configuration with no sensible
  -- default, so it is spelled out. `settings.content` is left unset on
  -- purpose: the documented install enables a module without a settings table
  -- beside it, and this profile is where that has to keep working.
  settings.tag = {
    entities = {
      content = true,
    },
  }

  -- Roles and permissions come from the tables INSTALL.md creates. Without
  -- this the module reads its roles from settings only, every permission
  -- check fails, and the anonymous permission query -- the one warm query the
  -- budget is stated in terms of -- never happens.
  settings.user = {
    permissions_storage = true,
  }

  -- Counting is what this instance exists for, so it is on for every request
  -- rather than gated by a scenario. `db_query_stats()` reads the setting once
  -- per worker, so it has to be true from the worker's first request.
  settings.performance = {
    query_stats = true,
  }

  -- This profile is the one that configures a cron token, so both halves of
  -- the gate are covered across the suite: `cron_smoke` on the other instance
  -- has none and must still be allowed, and `/cron` here has one and must
  -- refuse a caller without it.
  settings.cron = {
    token = (vault.cron or {}).token,
  }

  if db_path and db_path ~= '' then
    settings.db = {
      default = {
        driver = 'SQLite3',
        database = db_path,
      },
    }
  end

  settings.theme = {
    name = 'basic',
  }
end
LUA

  cat > "$SMOKE_DB_DOCROOT/vault.lua" <<'LUA'
return {
  site = {
    hash = 'ophal-smoke-hash',
  },
  cron = {
    token = 'smoke-cron-token',
  },
}
LUA

  cat > "$SMOKE_DB_CONF" <<EOF
env OPHAL_SMOKE_TMP;
env OPHAL_SMOKE_DB;
worker_processes 1;
pid logs/nginx.pid;
error_log logs/error.log info;

events {
  worker_connections 1024;
}

http {
  lua_package_path '$VENDOR_LUA_PATH';
  lua_package_cpath '$VENDOR_LUA_CPATH';

  lua_shared_dict ophal_projection_versions 1m;

  access_log logs/access.log;
  client_body_temp_path client_body_temp;
  proxy_temp_path proxy_temp;
  fastcgi_temp_path fastcgi_temp;
  uwsgi_temp_path uwsgi_temp;
  scgi_temp_path scgi_temp;

  server {
    listen 127.0.0.1:$SMOKE_DB_PORT;
    server_name example.com;
    root $SMOKE_DB_DOCROOT;

    # Shaped like the /cron location in nginx.ophal.conf, allow/deny included,
    # because the drain endpoint's two guards are meant to be tested together.
    # curl reaches it from 127.0.0.1, so the assertions turn on the token.
    location = /cron {
      allow 127.0.0.1;
      deny all;

      lua_code_cache on;
      default_type text/html;
      set \$ophal_script_name /cron.lua;
      rewrite_by_lua_block {
        require('lfs').chdir(ngx.var.document_root)
      }
      content_by_lua_file \$document_root/cron.lua;
    }

    location = /__smoke__ {
      lua_code_cache on;
      default_type text/html;
      set \$ophal_script_name /index.lua;
      rewrite_by_lua_block {
        require('lfs').chdir(ngx.var.document_root)
      }
      content_by_lua_file $ROOT/tests/smoke/openresty_runner.lua;
    }

    location = /__ophal_index__ {
      internal;
      lua_code_cache on;
      default_type text/html;
      set \$ophal_script_name /index.lua;
      rewrite_by_lua_block {
        require('lfs').chdir(ngx.var.document_root)
      }
      content_by_lua_file \$document_root/index.lua;
    }

    location = /index.lua { return 404; }
    location = /cron.lua { return 404; }
    location = /settings.lua { return 404; }
    location = /vault.lua { return 404; }
    location ^~ /includes/ { return 404; }
    location ^~ /modules/ { return 404; }

    location ~ \.lua\$ {
      return 404;
    }

    location / {
      try_files \$uri /__ophal_index__;
    }
  }
}
EOF
}

# Creates the database the measured instance reads. The normalized schema and
# rows come from the seed script; the projection tables come from the real
# migration CLI, so the harness installs the site the way the documentation
# says to rather than carrying a second copy of the schema.
seed_database() {
  local output status
  local -a seed_env

  seed_env=(
    "LUA_PATH=$VENDOR_LUA_PATH"
    "LUA_CPATH=$VENDOR_LUA_CPATH"
    "OPHAL_SMOKE_TMP=$SMOKE_ROOT"
    "OPHAL_SMOKE_DB=$SMOKE_DB_FILE"
  )
  if [[ -n "$VENDOR_LD_LIB_DIR" ]]; then
    seed_env=("LD_LIBRARY_PATH=$VENDOR_LD_LIB_DIR${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" "${seed_env[@]}")
  fi

  LAST_SCENARIO='database_seed'
  set +e
  output=$(cd "$SMOKE_DB_DOCROOT" && env -i "${seed_env[@]}" \
    lua5.1 "$ROOT/tests/smoke/seed_database.lua" "$SMOKE_DB_FILE" 2>&1)
  status=$?
  set -e
  LAST_OUTPUT=$output
  LAST_STATUS=$status
  [[ $status -eq 0 ]] || fail 'database seed failed'

  SEED_CONTENT_TITLE=$(extract_marker 'SEED_CONTENT_TITLE')
  SEED_CONTENT_BODY=$(extract_marker 'SEED_CONTENT_BODY')
  SEED_SECOND_TITLE=$(extract_marker 'SEED_SECOND_TITLE')
  SEED_UNPROMOTED_TITLE=$(extract_marker 'SEED_UNPROMOTED_TITLE')
  SEED_TAG_NAME=$(extract_marker 'SEED_TAG_NAME')
  SEED_ALIAS=$(extract_marker 'SEED_ALIAS')
  SEED_AUTHOR_NAME=$(extract_marker 'SEED_AUTHOR_NAME')
  SEED_AUTHOR_PASS=$(extract_marker 'SEED_AUTHOR_PASS')

  [[ -n "$SEED_CONTENT_TITLE" && -n "$SEED_TAG_NAME" && -n "$SEED_ALIAS" &&
     -n "$SEED_AUTHOR_NAME" && -n "$SEED_AUTHOR_PASS" ]] ||
    fail 'database seed did not report its fixtures'

  LAST_SCENARIO='database_migrate'
  set +e
  output=$(cd "$SMOKE_DB_DOCROOT" && env -i "${seed_env[@]}" \
    lua5.1 "$ROOT/ophal" migrate apply 2>&1)
  status=$?
  set -e
  LAST_OUTPUT=$output
  LAST_STATUS=$status
  [[ $status -eq 0 ]] || fail 'ophal migrate apply failed'
  report_ok database_seed
}

start_db_openresty() {
  local output

  set +e
  output=$(OPHAL_SMOKE_TMP="$SMOKE_ROOT" OPHAL_SMOKE_DB="$SMOKE_DB_FILE" \
    openresty -t -p "$SMOKE_DB_PREFIX" -c "$SMOKE_DB_CONF" 2>&1)
  LAST_STATUS=$?
  set -e
  LAST_OUTPUT=$output
  [[ "$LAST_STATUS" -eq 0 ]] || fail 'openresty database config test failed'

  OPHAL_SMOKE_TMP="$SMOKE_ROOT" OPHAL_SMOKE_DB="$SMOKE_DB_FILE" \
    openresty -p "$SMOKE_DB_PREFIX" -c "$SMOKE_DB_CONF"

  for _ in $(seq 1 50); do
    if port_ready "$SMOKE_DB_PORT"; then
      return 0
    fi
    sleep 0.1
  done

  fail 'database openresty did not become ready'
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

run_request index_prefixed_path_and_query "$BASE_URL/lorem_ipsum?foo=bar"
assert_status_zero
assert_regex '^HTTP/1\.[01] 200'
assert_contains 'Lorem Ipsum'
report_ok index_prefixed_path_and_query

run_request not_found "$BASE_URL/does-not-exist"
assert_status_zero
assert_regex '^HTTP/1\.[01] 404'
assert_contains 'The requested page could not be found.'
report_ok not_found

run_request projection_shared_dict "$BASE_URL/__smoke__?scenario=projection_shared_dict"
assert_status_zero
assert_regex '^HTTP/1\.[01] 200'
assert_contains 'SMOKE_DICT_DECLARED=true'
assert_contains 'SMOKE_DICT_VERSION=12345'
report_ok projection_shared_dict

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

upload_cookie="$SMOKE_ROOT/upload-cookie.txt"
upload_name="smoke-upload.txt"
upload_id="smoke-upload-id-1"

run_request file_upload_csrf -c "$upload_cookie" -b "$upload_cookie" "$BASE_URL/__smoke__?scenario=csrf_token"
assert_status_zero
assert_regex '^HTTP/1\.[01] 200'
upload_token=$(extract_marker 'SMOKE_CSRF_TOKEN')
[[ -n "$upload_token" ]] || fail 'missing CSRF token for file upload smoke'
report_ok file_upload_csrf

run_request file_upload_chunk \
  -c "$upload_cookie" -b "$upload_cookie" \
  -X POST \
  -H "X-CSRF-Token: $upload_token" \
  --data 'alpha=part-' \
  "$BASE_URL/__smoke__?scenario=file_upload_chunk&name=$upload_name&id=$upload_id&index=0"
assert_status_zero
assert_regex '^HTTP/1\.[01] 200'
assert_contains 'SMOKE_UPLOAD_SUCCESS=true'
assert_contains 'SMOKE_UPLOAD_BODY=alpha=part-'
report_ok file_upload_chunk

run_request file_merge_chunks \
  -c "$upload_cookie" -b "$upload_cookie" \
  -X POST \
  -H "X-CSRF-Token: $upload_token" \
  "$BASE_URL/__smoke__?scenario=file_merge_chunks&name=$upload_name&id=$upload_id&size=11&index=1"
assert_status_zero
assert_regex '^HTTP/1\.[01] 200'
assert_contains 'SMOKE_MERGE_SUCCESS=true'
report_ok file_merge_chunks

run_request cron_smoke "$BASE_URL/cron"
assert_status_zero
assert_regex '^HTTP/1\.[01] 200'
assert_regex '^X-Frame-Options: SAMEORIGIN'
report_ok cron_smoke

run_request entrypoint_hidden "$BASE_URL/index.lua"
assert_status_zero
assert_regex '^HTTP/1\.[01] 404'
report_ok entrypoint_hidden

run_request cron_entrypoint_hidden "$BASE_URL/cron.lua"
assert_status_zero
assert_regex '^HTTP/1\.[01] 404'
report_ok cron_entrypoint_hidden

run_request settings_hidden "$BASE_URL/settings.lua"
assert_status_zero
assert_regex '^HTTP/1\.[01] 404'
report_ok settings_hidden

run_request includes_hidden "$BASE_URL/includes/bootstrap.lua"
assert_status_zero
assert_regex '^HTTP/1\.[01] 404'
report_ok includes_hidden

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

# ================================================================
# Database profile (second instance, lua_code_cache on, real SQLite)
# The unit budget tests measure handlers with the database stubbed. These
# measure whole requests: nginx, bootstrap, routing, theme and SQLite.
# ================================================================

prepare_db_tree
seed_database
start_db_openresty

# Reads the worker's cumulative counters. The probe does not bootstrap, so it
# does not disturb what it measures.
read_db_stats() {
  local saved_scenario=$LAST_SCENARIO

  run_request db_stats_probe "$DB_URL/__smoke__?scenario=db_stats"
  assert_status_zero
  assert_regex '^HTTP/1\.[01] 200'
  DB_STATS_TOTAL=$(extract_marker 'SMOKE_DB_TOTAL')
  DB_STATS_NORMALIZED=$(extract_marker 'SMOKE_DB_NORMALIZED')
  DB_STATS_INFRASTRUCTURE=$(extract_marker 'SMOKE_DB_INFRASTRUCTURE')
  DB_STATS_TABLES=$(printf '%s\n' "$LAST_OUTPUT" | sed -n 's/^SMOKE_DB_TABLE_//p' | tr '\r' ' ' | tr '\n' ' ')
  [[ -n "$DB_STATS_TOTAL" && -n "$DB_STATS_NORMALIZED" && -n "$DB_STATS_INFRASTRUCTURE" ]] ||
    fail 'query stats probe reported nothing'
  LAST_SCENARIO=$saved_scenario
}

# Runs one request between two probes and leaves the request's own response in
# LAST_OUTPUT, so the assert_* helpers still describe the page rather than the
# probe that followed it.
measure_request() {
  local name=$1
  shift
  local before_total before_normalized before_infrastructure
  local measured_output measured_status

  read_db_stats
  before_total=$DB_STATS_TOTAL
  before_normalized=$DB_STATS_NORMALIZED
  before_infrastructure=$DB_STATS_INFRASTRUCTURE
  MEASURED_TABLES_BEFORE=$DB_STATS_TABLES

  run_request "$name" "$@"
  measured_output=$LAST_OUTPUT
  measured_status=$LAST_STATUS

  read_db_stats
  MEASURED_TOTAL=$((DB_STATS_TOTAL - before_total))
  MEASURED_NORMALIZED=$((DB_STATS_NORMALIZED - before_normalized))
  MEASURED_INFRASTRUCTURE=$((DB_STATS_INFRASTRUCTURE - before_infrastructure))
  MEASURED_TABLES=$DB_STATS_TABLES

  LAST_OUTPUT=$measured_output
  LAST_STATUS=$measured_status
  LAST_SCENARIO=$name
}

# The third argument is optional and defaults to zero, because no measured path
# should touch the queue or the migration ledger unless it says so. A scenario
# that expects an enqueue names the number; every other scenario asserts the
# absence of one by saying nothing.
assert_query_budget() {
  local expected_total=$1 expected_normalized=$2 expected_infrastructure=${3:-0}

  [[ "$MEASURED_NORMALIZED" -eq "$expected_normalized" ]] ||
    fail "expected $expected_normalized normalized queries, measured $MEASURED_NORMALIZED
  before: $MEASURED_TABLES_BEFORE
  after:  $MEASURED_TABLES"
  [[ "$MEASURED_INFRASTRUCTURE" -eq "$expected_infrastructure" ]] ||
    fail "expected $expected_infrastructure infrastructure queries, measured $MEASURED_INFRASTRUCTURE
  before: $MEASURED_TABLES_BEFORE
  after:  $MEASURED_TABLES"
  [[ "$MEASURED_TOTAL" -eq "$expected_total" ]] ||
    fail "expected $expected_total queries, measured $MEASURED_TOTAL
  before: $MEASURED_TABLES_BEFORE
  after:  $MEASURED_TABLES"
}

# Cold pass. This is the request that builds every projection from the seeded
# normalized tables, which is why it is not measured: it is the rebuild, not
# the delivery.
run_request db_frontpage_cold "$DB_URL/"
assert_status_zero
assert_regex '^HTTP/1\.[01] 200'
assert_contains "$SEED_CONTENT_TITLE"
report_ok db_frontpage_cold

run_request db_content_cold "$DB_URL/content/1"
assert_status_zero
assert_regex '^HTTP/1\.[01] 200'
report_ok db_content_cold

run_request db_tag_cold "$DB_URL/tag/1"
assert_status_zero
assert_regex '^HTTP/1\.[01] 200'
report_ok db_tag_cold

run_request db_alias_cold "$DB_URL/$SEED_ALIAS"
assert_status_zero
assert_regex '^HTTP/1\.[01] 200'
report_ok db_alias_cold

# The cold pass no longer builds anything. Each of those four requests found a
# projection that had never been built, served the page from the normalized
# source, and queued one rebuild -- deduplicated, so four requests over three
# projections leave three jobs, not twelve. This is what the phase is for: the
# unbounded work is off the request, and the requests above still rendered the
# right pages, which the assertions on their content already proved.
#
# So the drain has to happen here, and every budget below now depends on it.
# That is not an artifact of the test: it is the deployment contract. A site
# that never runs cron serves correct pages forever from the fallback and never
# gets the projections, until the pending marker's TTL lapses and one unlucky
# request rebuilds inline.
run_request db_cron_builds_projections "$DB_URL/cron?token=smoke-cron-token"
assert_status_zero
assert_regex '^HTTP/1\.[01] 200'
report_ok db_cron_builds_projections

run_request db_jobs_after_build "$DB_URL/__smoke__?scenario=jobs_status"
assert_status_zero
assert_contains 'SMOKE_JOBS_PENDING=0'
report_ok db_jobs_after_build

# The drain stamped every projection version with the second it ran in, and a
# load running in that same second is deliberately not reusable: a version is a
# unix second, so one written during a load cannot be told apart from one the
# load already saw. Stepping past that second is what makes the numbers below
# the steady state rather than the boundary. The boundary itself is pinned in
# `test_projection_runtime.lua`, where the clock can be frozen.
sleep 1

# One unmeasured pass over the freshly built projections. It is the first read
# of each of them, so it is what fills the per-worker payload caches -- the cold
# pass above could not, because it never touched a projection. It also loads the
# route table into the worker, which is what the requests below then reuse.
# Measuring here would measure the fill; the pass after it is the delivery.
for prime_path in "/" "/content/1" "/tag/1" "/$SEED_ALIAS"; do
  run_request db_prime "$DB_URL$prime_path"
  assert_status_zero
  assert_regex '^HTTP/1\.[01] 200'
done
report_ok db_projections_primed

# Warm pass. Every assertion below is on a whole request, so a page that
# renders nothing would also report zero queries -- the content assertions are
# what stop the budget from being satisfied by an empty response.
#
# These numbers do not depend on how long the warm pass takes to reach. They
# once did: a source key with no `projection_version` row was re-read every time
# the negative cache lapsed, so a gap longer than
# `projection_version_miss_ttl` between the cold and warm passes bought an extra
# query. The rebuilds now record the source version they read, so there is no
# absent key left to re-read. Setting that TTL to 0 in the profile settings
# above is the way to check that claim again after changing a projection.
measure_request db_frontpage_warm "$DB_URL/"
assert_status_zero
assert_regex '^HTTP/1\.[01] 200'
assert_contains "$SEED_CONTENT_TITLE"
assert_contains "$SEED_SECOND_TITLE"
# Both are `PRAGMA busy_timeout` and the `PRAGMA journal_mode` read, which every
# connection runs -- and bootstrap opens one per request. No table is read at
# all: the route alias index was the third query here until the worker started
# keeping the table it built, and nothing else on an anonymous render reaches
# SQL. Two connections' worth of setup is the whole cost of the page.
assert_query_budget 2 0
report_ok "db_frontpage_warm (total=$MEASURED_TOTAL normalized=$MEASURED_NORMALIZED)"

measure_request db_content_warm "$DB_URL/content/1"
assert_status_zero
assert_regex '^HTTP/1\.[01] 200'
assert_contains "$SEED_CONTENT_TITLE"
assert_contains "$SEED_CONTENT_BODY"
# A content page reads no normalized table. The last one was the tag module's
# `entity_load` join, now served from the payload cache under the
# `tag_listing_source` version.
assert_query_budget 2 0
report_ok "db_content_warm (total=$MEASURED_TOTAL normalized=$MEASURED_NORMALIZED)"

measure_request db_tag_warm "$DB_URL/tag/1"
assert_status_zero
assert_regex '^HTTP/1\.[01] 200'
assert_contains "$SEED_TAG_NAME"
assert_query_budget 2 0
report_ok "db_tag_warm (total=$MEASURED_TOTAL normalized=$MEASURED_NORMALIZED)"

measure_request db_alias_warm "$DB_URL/$SEED_ALIAS"
assert_status_zero
assert_regex '^HTTP/1\.[01] 200'
assert_contains "$SEED_CONTENT_TITLE"
# Same page as db_content_warm, reached through the route alias. The alias
# itself costs nothing extra, which is what this budget matching the direct
# route's is saying.
assert_query_budget 2 0
report_ok "db_alias_warm (total=$MEASURED_TOTAL normalized=$MEASURED_NORMALIZED)"

# ================================================================
# Authoring profile (same instance, signed in)
# Every budget above is a read. These measure a write, and then measure the
# read that follows it, because a projection design can always make writes look
# cheap by leaving the work for the next visitor to pay. Both halves have to be
# on the record for Phase 5 to have a baseline to move work off.
# ================================================================

# Authored, not seeded: these strings are created through the save service, so
# they are spelled here rather than in seed_database.lua. A page that shows one
# of them proves the write reached the projection the reader is served from.
AUTHORED_TITLE='Smoke Authored Article'
AUTHORED_BODY='SMOKE_AUTHORED_BODY_MARKER'
AUTHORED_UPDATED_TITLE='Smoke Authored Article Revised'
AUTHORED_UPDATED_BODY='SMOKE_AUTHORED_REVISED_MARKER'

author_cookie="$SMOKE_ROOT/db-author-cookie.txt"

# Signing in is deliberately not measured. It is the cold pass for this
# account's role, permission and user caches, and it also rewrites the seeded
# legacy password hash in the current format, so what it costs describes a
# first login rather than authoring.
run_request db_author_login -c "$author_cookie" -b "$author_cookie" \
  -H 'Content-Type: application/json' \
  --data-binary "{\"user\":\"$SEED_AUTHOR_NAME\",\"pass\":\"$SEED_AUTHOR_PASS\"}" \
  "$DB_URL/user/auth"
assert_status_zero
assert_regex '^HTTP/1\.[01] 200'
assert_regex '"authenticated" *: *true'
report_ok db_author_login

# The save service validates a CSRF token, and the token belongs to the session
# the cookie jar now carries. Reading it through the runner rather than parsing
# it out of a form keeps this independent of how the form renders.
run_request db_author_csrf -c "$author_cookie" -b "$author_cookie" "$DB_URL/__smoke__?scenario=csrf_token"
assert_status_zero
assert_regex '^HTTP/1\.[01] 200'
author_csrf=$(extract_marker 'SMOKE_CSRF_TOKEN')
[[ -n "$author_csrf" ]] || fail 'signed-in session reported no CSRF token'
report_ok db_author_csrf

# Warms this account's caches. An authenticated request pays four permission
# queries the first time a worker sees the user id; that cost belongs to the
# session, not to the page, so it is spent here rather than inside a budget.
run_request db_author_frontpage_cold -c "$author_cookie" -b "$author_cookie" "$DB_URL/"
assert_status_zero
assert_regex '^HTTP/1\.[01] 200'
report_ok db_author_frontpage_cold

measure_request db_author_frontpage_warm -c "$author_cookie" -b "$author_cookie" "$DB_URL/"
assert_status_zero
assert_regex '^HTTP/1\.[01] 200'
assert_contains "$SEED_CONTENT_TITLE"
# The same budget as the anonymous front page. Signing in adds nothing to a
# warm read: the account, its roles and its permissions are all per-worker
# cached by then, which is the end-to-end version of what
# test_user_permissions.lua pins at the handler level.
assert_query_budget 2 0
report_ok "db_author_frontpage_warm (total=$MEASURED_TOTAL normalized=$MEASURED_NORMALIZED)"

# The create. Tags are included because `entity_after_save()` is where the tag
# module does its writing, and a create without them would measure only half of
# what saving a real article costs.
measure_request db_content_create -c "$author_cookie" -b "$author_cookie" \
  -H 'Content-Type: application/json' \
  -H "X-CSRF-Token: $author_csrf" \
  --data-binary "{\"title\":\"$AUTHORED_TITLE\",\"teaser\":\"$AUTHORED_BODY\",\"body\":\"$AUTHORED_BODY\",\"status\":true,\"promote\":true,\"tags\":[1]}" \
  "$DB_URL/content/save"
assert_status_zero
assert_regex '^HTTP/1\.[01] 200'
assert_regex '"success" *: *true'
authored_id=$(printf '%s\n' "$LAST_OUTPUT" | sed -n 's/.*"id" *: *\([0-9][0-9]*\).*/\1/p' | tail -n 1)
[[ -n "$authored_id" ]] || fail 'content save reported no id'
# A characterization budget, not a target. It is here so that a change to the
# write path has to state what it did to the cost, and the breakdown is what
# makes the number readable:
#
#   projection_version   4   four touch() calls, one upsert each
#   content_public       3   the projection DELETE and INSERT, and the tag
#                            rebuild's source read, which joins it
#   content              2   the INSERT, then load_legacy() in entity_after_save
#   field_tag            3   the existing-tags read, the INSERT, the rebuild's
#                            source read
#   tag_listing_index    3   one DELETE plus a row per tagged entity
#   route_index          1   the route lookup every request pays
#   tag                  1
#   plus the connection's two pragmas
#
# Seventeen table hits over sixteen queries, because the tag rebuild's source
# read names `content_public` and `field_tag` both.
#
# This was 26 and 6 when the path was first measured. Three changes took the
# eight off, none of them structural: `save_service()` stopped calling
# `load(id)` before it knew the action, which had been looking up id 0 in
# `content_public` and then in `content` for two certain misses;
# `entity_after_save()` stopped touching `tag_listing_source` a second time from
# inside `tag_projection_rebuild()`; and `projection.touch()` became a single
# upsert instead of a DELETE plus an INSERT.
assert_query_budget 17 5
report_ok "db_content_create (total=$MEASURED_TOTAL normalized=$MEASURED_NORMALIZED)"

# What the write left for the next visitor. This is anonymous on purpose: the
# author's own caches were warmed by the write, so measuring the author here
# would hide whatever the write invalidated for everybody else.
measure_request db_frontpage_after_create "$DB_URL/"
assert_status_zero
assert_regex '^HTTP/1\.[01] 200'
assert_contains "$AUTHORED_TITLE"
# Two more queries than a warm read, both against `content_public`: the front
# page's cached count and row list, reloaded because the write moved the version
# they were stamped with. `cached_value()` invalidates by comparing versions
# rather than by the bucket `projection_touch()` also drops. Still no normalized
# read. This is the number Phase 5 would be moving, so it is pinned apart from
# the write's own cost.
assert_query_budget 4 0
report_ok "db_frontpage_after_create (total=$MEASURED_TOTAL normalized=$MEASURED_NORMALIZED)"

measure_request db_content_update -c "$author_cookie" -b "$author_cookie" \
  -H 'Content-Type: application/json' \
  -H "X-CSRF-Token: $author_csrf" \
  --data-binary "{\"title\":\"$AUTHORED_UPDATED_TITLE\",\"teaser\":\"$AUTHORED_UPDATED_BODY\",\"body\":\"$AUTHORED_UPDATED_BODY\",\"status\":true,\"promote\":true,\"tags\":[1]}" \
  "$DB_URL/content/save/$authored_id"
assert_status_zero
assert_regex '^HTTP/1\.[01] 200'
assert_regex '"success" *: *true'
# An update now costs exactly what a create does. It reads one more row from
# `content_public` -- `load(id)`, which an update genuinely needs and a create
# no longer performs -- and does one less insert-side write. It was 24 before
# the same pass; six of those were `projection_version` pairs.
assert_query_budget 17 5
report_ok "db_content_update (total=$MEASURED_TOTAL normalized=$MEASURED_NORMALIZED)"

measure_request db_content_page_after_update "$DB_URL/content/$authored_id"
assert_status_zero
assert_regex '^HTTP/1\.[01] 200'
assert_contains "$AUTHORED_UPDATED_TITLE"
assert_contains "$AUTHORED_UPDATED_BODY"
# The one normalized read is the tag `entity_load` join, and it is here by
# design rather than by oversight. That cache is keyed on `tag_listing_source`
# -- the only version every `field_tag` write is guaranteed to move -- so any
# tag write anywhere invalidates every entity's cached tag set, not just the
# entity that changed. The safe key is the coarse one; a finer key would need a
# per-entity source version. Until then this is what the first reader after a
# tag write pays.
assert_query_budget 4 1
report_ok "db_content_page_after_update (total=$MEASURED_TOTAL normalized=$MEASURED_NORMALIZED)"

# The tag listing has to show the authored article too, or the tag rows the
# save wrote never reached the listing projection. This is the only assertion
# that covers the tag half of `entity_after_save()` end to end.
measure_request db_tag_after_update "$DB_URL/tag/1"
assert_status_zero
assert_regex '^HTTP/1\.[01] 200'
assert_contains "$SEED_TAG_NAME"
assert_contains "$AUTHORED_UPDATED_TITLE"
# The listing's own tag entity is keyed on `tag_listing_index`, which the write
# moved, so it comes back from the normalized `tag` table once. The listing
# rows themselves are still projection reads.
assert_query_budget 5 1
report_ok "db_tag_after_update (total=$MEASURED_TOTAL normalized=$MEASURED_NORMALIZED)"

# ---------------------------------------------------------------------------
# The cron endpoint's token gate
#
# This is the only profile that configures `settings.cron.token`, which is why
# both halves are covered: `cron_smoke` on the other instance has no token and
# must still be served, because refusing there would break every deployment
# that upgrades without editing its vault. Here a token exists, so a caller
# without it must be refused.
#
# The `allow 127.0.0.1; deny all;` in this profile's /cron location is shipped
# in nginx.ophal.conf too. curl reaches it from 127.0.0.1, so these assertions
# turn on the Lua gate rather than on the nginx one -- which is the point, since
# the token is what protects a site whose cron runs from another host.

# The queue, end to end, against a real SQLite file: enqueue, refuse, drain,
# observe. It is interleaved with the token assertions on purpose -- a refused
# request has to leave the queue alone, which is the part of the gate that
# actually matters. A 403 that had already drained the queue would still pass an
# assertion on the status line.

run_request db_jobs_enqueue "$DB_URL/__smoke__?scenario=jobs_enqueue"
assert_status_zero
assert_regex '^HTTP/1\.[01] 200'
assert_contains 'SMOKE_JOBS_ENQUEUED=true'
assert_contains 'SMOKE_JOBS_PENDING=1'
report_ok db_jobs_enqueue

run_request db_cron_requires_token "$DB_URL/cron"
assert_status_zero
assert_regex '^HTTP/1\.[01] 403'
report_ok db_cron_requires_token

run_request db_cron_rejects_wrong_token "$DB_URL/cron?token=not-the-token"
assert_status_zero
assert_regex '^HTTP/1\.[01] 403'
report_ok db_cron_rejects_wrong_token

run_request db_jobs_survive_refused_cron "$DB_URL/__smoke__?scenario=jobs_status"
assert_status_zero
assert_regex '^HTTP/1\.[01] 200'
assert_contains 'SMOKE_JOBS_PENDING=1'
assert_contains 'SMOKE_JOBS_STATUS=pending'
report_ok db_jobs_survive_refused_cron

run_request db_cron_authorized "$DB_URL/cron?token=smoke-cron-token"
assert_status_zero
assert_regex '^HTTP/1\.[01] 200'
report_ok db_cron_authorized

# The claim, the handler dispatch, the payload round trip through JSON and the
# completion, all against a real database. This is the only place the SQLite
# claim statement is executed rather than pattern-matched.
run_request db_jobs_drained "$DB_URL/__smoke__?scenario=jobs_status"
assert_status_zero
assert_regex '^HTTP/1\.[01] 200'
assert_contains 'SMOKE_JOBS_PENDING=0'
assert_contains 'SMOKE_JOBS_STATUS=done'
assert_contains 'SMOKE_JOBS_HANDLER=smoke handler ran'
report_ok db_jobs_drained

run_request db_cron_header_token "$DB_URL/cron" \
  -H 'X-Ophal-Cron-Token: smoke-cron-token'
assert_status_zero
assert_regex '^HTTP/1\.[01] 200'
report_ok db_cron_header_token

# ---------------------------------------------------------------------------
# A projection that falls behind after it was built
#
# The cold pass above covered the never-built case. This is the other one, and
# the one the phase is named for: a projection exists, its source moves ahead of
# it, and the request that notices must not be the one that rebuilds it. On a
# real site that happens after a restore, a CLI write, or a rebuild that failed
# partway.

run_request db_make_content_stale "$DB_URL/__smoke__?scenario=stale_projection&key=content_public"
assert_status_zero
assert_contains 'SMOKE_STALE_VERSION=1'
report_ok db_make_content_stale

# Correct page, bounded cost, and one write to the queue rather than a rebuild.
# Five: the two connection pragmas, the fallback's count and page of rows
# straight from `content`, and the enqueue. Bounded is the word
# that matters -- the two normalized reads are one page of content, not the
# whole table, which is what the rebuild this replaced would have read.
#
# The enqueue is counted apart from both other buckets. A normalized read means
# the request reconstructed source data, and these two did; the queue write is
# not that, and hiding it in either number would make one of them stop meaning
# what every other budget in this file uses it to mean.
measure_request db_frontpage_stale "$DB_URL/"
assert_status_zero
assert_regex '^HTTP/1\.[01] 200'
assert_contains "$SEED_CONTENT_TITLE"
assert_contains "$SEED_SECOND_TITLE"
assert_query_budget 5 2 1
report_ok "db_frontpage_stale (total=$MEASURED_TOTAL normalized=$MEASURED_NORMALIZED infrastructure=$MEASURED_INFRASTRUCTURE)"

# The second reader in the same window queues nothing: the unique index on
# `active_key` is what keeps a stale window costing one job instead of one per
# request. Same page, same fallback, no infrastructure query at all.
measure_request db_frontpage_stale_again "$DB_URL/"
assert_status_zero
assert_regex '^HTTP/1\.[01] 200'
assert_contains "$SEED_CONTENT_TITLE"
assert_query_budget 4 2 0
report_ok "db_frontpage_stale_again (total=$MEASURED_TOTAL normalized=$MEASURED_NORMALIZED)"

run_request db_cron_rebuilds_stale "$DB_URL/cron?token=smoke-cron-token"
assert_status_zero
assert_regex '^HTTP/1\.[01] 200'
report_ok db_cron_rebuilds_stale

run_request db_reprime "$DB_URL/"
assert_status_zero
assert_regex '^HTTP/1\.[01] 200'
report_ok db_reprime

# And the budget comes back. This is the assertion that says the whole loop
# closed: stale, deferred, served from source, queued once, drained, current.
measure_request db_frontpage_after_rebuild "$DB_URL/"
assert_status_zero
assert_regex '^HTTP/1\.[01] 200'
assert_contains "$SEED_CONTENT_TITLE"
assert_contains "$SEED_SECOND_TITLE"
assert_query_budget 2 0
report_ok "db_frontpage_after_rebuild (total=$MEASURED_TOTAL normalized=$MEASURED_NORMALIZED)"

# The alias table is worker state now, so the last thing to prove is that a
# worker which has stopped reading it still sees a write. It has to: a route
# write moves both versions, and the guard reads them before it reuses
# anything.
SEED_LATE_ALIAS='late-smoke-alias'

run_request db_alias_created \
  "$DB_URL/__smoke__?scenario=create_alias&source=content/1&alias=$SEED_LATE_ALIAS"
assert_status_zero
assert_contains "SMOKE_ALIAS_CREATED=$SEED_LATE_ALIAS"
report_ok db_alias_created

# The write and the load that notices it have to fall in different seconds, or
# the load is correct but not reusable and the measurement below is of the load
# after it instead. One second is the whole granularity of a version.
sleep 1

# The 404 question, and the answer has to be a page. This request is not
# measured: it is the first content page rendered since `db_cron_rebuilds_stale`
# moved `content_public` and `tag_listing_index`, so its budget is those payload
# caches refilling rather than anything about routes. The reload the write
# forces is pinned per-term in `test_projection_runtime.lua`.
run_request db_late_alias_resolves "$DB_URL/$SEED_LATE_ALIAS"
assert_status_zero
assert_regex '^HTTP/1\.[01] 200'
assert_contains "$SEED_CONTENT_TITLE"
report_ok db_late_alias_resolves

# Back to two, on a URL that did not exist when this worker last read
# `route_index`. That is the whole claim: the write was noticed, and the table
# it produced is being reused.
measure_request db_late_alias_reused "$DB_URL/$SEED_LATE_ALIAS"
assert_status_zero
assert_regex '^HTTP/1\.[01] 200'
assert_contains "$SEED_CONTENT_TITLE"
assert_query_budget 2 0
report_ok "db_late_alias_reused (total=$MEASURED_TOTAL normalized=$MEASURED_NORMALIZED)"

printf 'all openresty smoke scenarios passed
'
