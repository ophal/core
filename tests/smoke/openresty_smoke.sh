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
# The lab `tests/bench/setup_backends.sh` vendors carries pgmoon, which the
# seeder and the migration CLI need to reach PostgreSQL. It also carries a `bit`
# binding, which pgmoon wanted under PUC Lua and which LuaJIT has built in --
# dead weight since 2026-09-10 and harmless. Appended rather than required: a
# checkout with no lab still runs the SQLite profile, and the directories simply
# miss.
BACKENDS_LUA="$VENDOR_ROOT/backends/lua"
BACKENDS_LUA_SHARE="$BACKENDS_LUA/share"
BACKENDS_LUA_LIB="$BACKENDS_LUA/usr/lib/x86_64-linux-gnu/lua/5.1"

VENDOR_LUA_PATH="./?.lua;./?/init.lua;$VENDOR_ROOT/?.lua;$VENDOR_ROOT/?/init.lua;$VENDOR_LUA_SHARE/?.lua;$VENDOR_LUA_SHARE/?/init.lua;$BACKENDS_LUA_SHARE/?.lua;$BACKENDS_LUA_SHARE/?/init.lua;;"
VENDOR_LUA_CPATH="$BACKENDS_LUA_LIB/?.so;;"
if [[ -n "$VENDOR_LUA_LIB_DIR" ]]; then
  VENDOR_LUA_CPATH="$VENDOR_LUA_LIB_DIR/?.so;$BACKENDS_LUA_LIB/?.so;;"
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
#
# Since stage 8.7 there is one such instance per backend rather than one, so
# every path, port and directory below is filled in by `db_profile_begin` and
# nothing about the profile is spelled `sqlite` any more. The scenarios
# themselves live in `tests/smoke/db_profile.sh`, which is sourced once per
# backend: the same list, in the same order, against each -- which is the only
# way "it works on PostgreSQL" means anything.
SMOKE_DB_BACKEND=''
SMOKE_DB_DOCROOT=''
SMOKE_DB_PREFIX=''
SMOKE_DB_CONF=''
SMOKE_DB_WORK=''
SMOKE_DB_FILES=''
SMOKE_DB_SESSIONS=''
SMOKE_DB_PORT=''
DB_URL=''
# Every prefix a profile has started, so cleanup can stop all of them rather
# than only the last.
SMOKE_DB_PREFIXES=()
SMOKE_DB_CONFS=()

# The vendored lab `tests/bench/setup_backends.sh` stands up. A backend that is
# not listening is reported and skipped rather than failing the run, because a
# clean checkout has no lab -- but the summary says which profiles ran, and
# `OPHAL_SMOKE_REQUIRE_BACKENDS=1` turns a skip into a failure for a build that
# is supposed to have them.
BACKENDS_ROOT="$ROOT/tests/smoke/vendor/backends"
BACKEND_PG_HOST="${OPHAL_SMOKE_PG_HOST:-127.0.0.1}"
BACKEND_PG_PORT="${OPHAL_SMOKE_PG_PORT:-15432}"
BACKEND_PG_USER="${OPHAL_SMOKE_PG_USER:-ophal}"
BACKEND_PG_PASS="${OPHAL_SMOKE_PG_PASS:-ophal}"
BACKEND_PG_DATABASE="${OPHAL_SMOKE_PG_DATABASE:-ophal_smoke}"
BACKEND_MY_HOST="${OPHAL_SMOKE_MY_HOST:-127.0.0.1}"
BACKEND_MY_PORT="${OPHAL_SMOKE_MY_PORT:-13306}"
BACKEND_MY_USER="${OPHAL_SMOKE_MY_USER:-ophal}"
BACKEND_MY_PASS="${OPHAL_SMOKE_MY_PASS:-ophal}"
BACKEND_MY_DATABASE="${OPHAL_SMOKE_MY_DATABASE:-ophal_smoke}"

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

# `OPHAL_SMOKE_KEEP=1` leaves the tree behind. A failure otherwise takes the
# database, the generated configuration and both error logs with it, which is
# most of the evidence for anything that goes wrong in the database profile.
cleanup() {
  openresty -p "$SMOKE_PREFIX" -c "$SMOKE_CONF" -s stop >/dev/null 2>&1 || true

  local i
  for i in "${!SMOKE_DB_PREFIXES[@]}"; do
    openresty -p "${SMOKE_DB_PREFIXES[$i]}" -c "${SMOKE_DB_CONFS[$i]}" -s stop \
      >/dev/null 2>&1 || true
  done

  if [[ -n "${OPHAL_SMOKE_KEEP:-}" ]]; then
    printf 'kept: %s\n' "$SMOKE_ROOT" >&2
  else
    rm -rf "$SMOKE_ROOT"
  fi
}
trap cleanup EXIT


check_dependencies() {
  local output_file status output probe_file
  local -a dep_env

  output_file=$(mktemp)
  dep_env=(
    "LUA_PATH=$VENDOR_LUA_PATH"
    "LUA_CPATH=$VENDOR_LUA_CPATH"
  )
  if [[ -n "$VENDOR_LD_LIB_DIR" ]]; then
    dep_env=("LD_LIBRARY_PATH=$VENDOR_LD_LIB_DIR${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" "${dep_env[@]}")
  fi

  #[[ Checked under `resty`, because that is what runs everything now.
  #
  # It ran under `env -i ... lua5.1` until 2026-09-10. Neither half survives:
  # Ophal is LuaJIT-only, and `resty` is not `env -i`-safe because it shells out
  # to nginx -- so the probe goes to a file and the environment is added to
  # rather than replaced. `dkjson` left the list with the JSON shim; `cjson`
  # replaces it, and checking for it is really checking that this is a real
  # OpenResty with its bundled libraries reachable.
  probe_file=$(mktemp)
  cat >"$probe_file" <<'LUA'
local missing = {}
for _, name in ipairs({'lfs', 'cjson', 'lsqlite3'}) do
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

  set +e
  env "${dep_env[@]}" resty --errlog-level=error "$probe_file" >"$output_file" 2>&1
  status=$?
  set -e
  rm -f "$probe_file"
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

assert_not_contains() {
  local needle=$1
  printf '%s' "$LAST_OUTPUT" | grep -Fq -- "$needle" && fail "unexpected text: $needle"
  return 0
}

# The negative form of `assert_regex`. A response is often defined as much by
# what it does not carry -- an ETag on a personal page, a Set-Cookie on a
# shareable one -- as by what it does.
assert_not_regex() {
  if printf '%s\n' "$LAST_OUTPUT" | grep -Eq "$1"; then
    fail "unexpected pattern: $1"
  fi
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
      try_files \$uri /__ophal_index__\$is_args\$args;
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
      try_files \$uri /__ophal_index__\$is_args\$args;
    }
  }
}
EOF
}

# Everything that makes one database profile differ from another.
#
# The scenarios are identical across backends by construction -- they are one
# sourced file -- so every difference between profiles has to be expressible
# here, in a connection and a set of paths. Anything that needs a branch in the
# scenario list is a difference in Ophal's behaviour on that backend, which is
# the thing this stage exists to find rather than to accommodate.
db_profile_begin() {
  local backend=$1

  SMOKE_DB_BACKEND=$backend
  SMOKE_DB_DOCROOT="$SMOKE_ROOT/db-$backend/docroot"
  SMOKE_DB_PREFIX="$SMOKE_ROOT/db-$backend/prefix"
  SMOKE_DB_CONF="$SMOKE_ROOT/db-$backend/nginx.conf"
  SMOKE_DB_WORK="$SMOKE_ROOT/db-$backend/work"
  SMOKE_DB_FILES="$SMOKE_ROOT/db-$backend/files"
  SMOKE_DB_SESSIONS="$SMOKE_ROOT/db-$backend/sessions"
  SMOKE_DB_PORT=$(pick_port)
  DB_URL="http://127.0.0.1:${SMOKE_DB_PORT}"

  # The connection, in the one shape both the seeder and the generated
  # settings.lua read. They take it from the environment rather than from each
  # other so the harness cannot seed one database and then measure another.
  SMOKE_DB_ENV_DRIVER=$backend
  SMOKE_DB_ENV_HOST=''
  SMOKE_DB_ENV_PORT=''
  SMOKE_DB_ENV_USER=''
  SMOKE_DB_ENV_PASS=''

  case "$backend" in
    sqlite3)
      SMOKE_DB_ENV_DATABASE="$SMOKE_ROOT/db-$backend/ophal-smoke.sqlite3"
      ;;
    postgresql)
      SMOKE_DB_ENV_DATABASE=$BACKEND_PG_DATABASE
      SMOKE_DB_ENV_HOST=$BACKEND_PG_HOST
      SMOKE_DB_ENV_PORT=$BACKEND_PG_PORT
      SMOKE_DB_ENV_USER=$BACKEND_PG_USER
      SMOKE_DB_ENV_PASS=$BACKEND_PG_PASS
      ;;
    mysql)
      SMOKE_DB_ENV_DATABASE=$BACKEND_MY_DATABASE
      SMOKE_DB_ENV_HOST=$BACKEND_MY_HOST
      SMOKE_DB_ENV_PORT=$BACKEND_MY_PORT
      SMOKE_DB_ENV_USER=$BACKEND_MY_USER
      SMOKE_DB_ENV_PASS=$BACKEND_MY_PASS
      ;;
    *)
      fail "no database profile is defined for the $backend backend"
      ;;
  esac

  PROFILE_COUNT=0
  PROFILE_LABEL="$backend"
  BUDGETS_CLOSED=''
}

# Runs a Lua program with this profile's environment, under `resty`.
#
# It used to pick the interpreter per backend: `lua5.1` for most, `resty` for
# MySQL, because `lua-resty-mysql` is cosockets down to the socket and has no
# blocking mode. Ophal became LuaJIT-only on 2026-09-10, so there is one
# interpreter again and it is the one the worker runs.
#
# `resty` is not `env -i`-safe -- it shells out to nginx -- so the variables are
# added to the environment rather than replacing it, and every LUA_* one is set
# explicitly so an ambient value cannot decide which modules are loaded.
db_run_cli() {
  local -a cli_env
  local line

  cli_env=(
    "LUA_PATH=$VENDOR_LUA_PATH"
    "LUA_CPATH=$VENDOR_LUA_CPATH"
  )
  if [[ -n "$VENDOR_LD_LIB_DIR" ]]; then
    cli_env+=("LD_LIBRARY_PATH=$VENDOR_LD_LIB_DIR${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}")
  fi
  while IFS= read -r line; do
    cli_env+=("$line")
  done < <(db_profile_env)

  (cd "$SMOKE_DB_DOCROOT" && env "${cli_env[@]}" resty -c 512 --errlog-level=error "$@" 2>&1)
}

# The environment both the seeder and the profile's OpenResty instance read.
db_profile_env() {
  printf '%s\n' \
    "OPHAL_SMOKE_TMP=$SMOKE_ROOT" \
    "OPHAL_SMOKE_DB_DRIVER=$SMOKE_DB_ENV_DRIVER" \
    "OPHAL_SMOKE_DB=$SMOKE_DB_ENV_DATABASE" \
    "OPHAL_SMOKE_DB_HOST=$SMOKE_DB_ENV_HOST" \
    "OPHAL_SMOKE_DB_PORT=$SMOKE_DB_ENV_PORT" \
    "OPHAL_SMOKE_DB_USER=$SMOKE_DB_ENV_USER" \
    "OPHAL_SMOKE_DB_PASS=$SMOKE_DB_ENV_PASS" \
    "OPHAL_SMOKE_FILES=$SMOKE_DB_FILES" \
    "OPHAL_SMOKE_SESSIONS=$SMOKE_DB_SESSIONS"
}

prepare_db_tree() {
  mkdir -p "$SMOKE_DB_DOCROOT" "$SMOKE_DB_PREFIX/logs" "$SMOKE_DB_PREFIX/client_body_temp" \
    "$SMOKE_DB_PREFIX/proxy_temp" "$SMOKE_DB_PREFIX/fastcgi_temp" "$SMOKE_DB_PREFIX/uwsgi_temp" \
    "$SMOKE_DB_PREFIX/scgi_temp" "$SMOKE_DB_WORK" "$SMOKE_DB_FILES" "$SMOKE_DB_SESSIONS"
  link_docroot "$SMOKE_DB_DOCROOT"

  # `theme_render()` resolves templates under themes/<name>/ only, and neither
  # shipped theme carries the content module's templates. A content site has to
  # copy them into its theme, so the profile does exactly that rather than
  # pretending the stock theme can render content.
  mkdir -p "$SMOKE_DB_DOCROOT/themes"
  cp -R "$ROOT/themes/basic" "$SMOKE_DB_DOCROOT/themes/basic"
  cp "$ROOT/modules/content/content_teaser.tpl.html" "$SMOKE_DB_DOCROOT/themes/basic/"
  cp "$ROOT/modules/content/content_page.tpl.html" "$SMOKE_DB_DOCROOT/themes/basic/"

  #[[ The comment module's template, copied from 2026-09-11.
  #
  # It was missing from the moment comments were enabled here, and nothing
  # said so: `theme_render()` **returned** its error as the rendered value, so
  # every `rendered` field in `comment/fetch`'s JSON was the string
  #
  #   template '/…/themes/basic/comment.tpl.html': cannot obtain information
  #   from file …: No such file or directory
  #
  # -- an absolute filesystem path, in a 200, to an anonymous client.
  # `assert_no_source_path` matches `.lua:<n>` and could not see it.
  # `assert_no_theme_error` found it within a minute of being added, which is
  # the second time a `report_ok` guard has caught a defect it was not written
  # for.
  cp "$ROOT/modules/comment/comment.tpl.html" "$SMOKE_DB_DOCROOT/themes/basic/"

  #[[ A menu, rendered into the page shell.
  #
  # `modules/menu` was in no profile, and it is worse than untested: **nothing
  # in the repository renders a menu**. `theme.menu` is defined only by that
  # module, and the one caller of `theme{'menu', ...}` is `modules/tag`'s
  # `theme.tags_menu()`, which no shipped template calls. So enabling the module
  # is not enough -- the profile's theme has to ask for a menu, which is what
  # this does.
  #
  # `primary_links` rather than `tags_menu`: `menus_alter` builds the tags
  # closure but does not run it, so this adds no query and every pinned budget
  # above stays where it is. That is the assertion -- if one moves, the menu is
  # doing database work.
  sed -i "s|<h1 class=\"title\">|<div id=\"nav\"><?lua print_t{'menu', id = 'primary_links'} ?></div>\n<h1 class=\"title\">|" \
    "$SMOKE_DB_DOCROOT/themes/basic/html.tpl.html"

  # This profile has no scenario switch. It is one configuration -- database on,
  # content, user and tag enabled, front page served by the content module --
  # because the whole point of a second instance is that its worker warms up
  # against a single, realistic site rather than a mixture.
  cat > "$SMOKE_DB_DOCROOT/settings.lua" <<'LUA'
return function(settings, vault)
  local getenv = os.getenv
  local tmp_root = getenv('OPHAL_SMOKE_TMP') or '.'

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
    files_path = getenv('OPHAL_SMOKE_FILES'),
  }
  settings.micro_cache = false
  settings.debugapi = false
  settings.maintenance_mode = false
  settings.output_buffering = false
  settings.sessionapi = {
    enabled = true,
    ttl = 86400,
    lock_ttl = 120,
    path = getenv('OPHAL_SMOKE_SESSIONS'),
  }
  settings.formapi = true
  settings.date_format = '!%Y-%m-%d %H:%M UTC'

  -- Aliases come from storage here, so the route projection is on the measured
  -- path instead of being a code path only the unit tests ever reach.
  settings.route_aliases_storage = true
  settings.route_aliases_prepend_language = false
  -- On here since 2026-09-10. `route_redirect` had no schema in INSTALL.md, in
  -- the migrations or in this seeder, so turning the setting on errored out of
  -- bootstrap phase 12 on every request -- and nothing exercised the six
  -- `route.redirect_*` statements, one of which named a column the table does
  -- not have.
  settings.route_redirects_storage = true
  settings.route_redirects_prepend_language = false

  --[[ The template and asset stat caches, turned off so the render budget is a
    number rather than a coin toss.

    Both are TTL caches over `lfs.attributes` with a default of **one second**,
    compared with `os.time()` -- so two requests inside the same second re-use
    the cached attributes and two a second apart do not. A pinned budget over
    that measures how fast the harness happened to be running, which is the
    same trap a projection version's one-second granularity sets.

    At 0 every render stats every template and every asset it touches, which is
    the honest per-render cost and the one worth ranking. The compile cache is
    untouched -- it is keyed by path and mtime, not by this -- so the budget
    separates metadata from compilation, which is the distinction `TODO.md`
    draws.
  ]]
  settings.runtime_cache = {
    stat_ttl = 0,
  }

  settings.modules = {
    content = true,
    user = true,
    tag = true,
    file = true,
    comment = true,
    -- On here since 2026-09-11, with the menu rendered into this profile's
    -- page shell. `modules/menu` had been in no profile at all.
    menu = true,
  }

  --[[ Comments are enabled here as of 2026-09-09, and the reason is coverage
    rather than features.

    The module was in no profile at all, which is how `save_service()` came to
    answer 401 for a comment that does not exist -- the same defect `modules/tag`
    had fixed in stage 8.5, sitting untested. It is also the projection
    candidate that rested on argument alone: the fetch service is an anonymous
    JSON read that walks normalized `comment` and then an account per row, and
    nothing had ever measured it.
  ]]
  settings.comment = {
    entities = {
      content = true,
    },
  }

  -- The media path is measured here rather than on the module-less instance
  -- because that one runs with `lua_code_cache off`, which resets
  -- `package.loaded` between requests -- the counters would be zero every time
  -- they were read. `filedb_storage` is on so the registration and the deferred
  -- type inspection execute against a real database and a real queue; the
  -- module-less profile leaves it off and covers the storage-only path.
  settings.file = {
    filedb_storage = true,
    bytes_per_chunk = 8,
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
    fs_stats = true,
  }

  -- This profile is the one that configures a cron token, so both halves of
  -- the gate are covered across the suite: `cron_smoke` on the other instance
  -- has none and must still be allowed, and `/cron` here has one and must
  -- refuse a caller without it.
  settings.cron = {
    token = (vault.cron or {}).token,
  }

  --[[ The connection, from the environment, in the shape
    `tests/smoke/seed_database.lua` reads it from.

    One profile per backend since stage 8.7, so the driver is no longer written
    here. A `port` of nil is what a file-backed backend wants and what pgmoon
    reads as its default, so the empty string is normalized away rather than
    passed on as a port named "".
  ]]
  local db_name = getenv('OPHAL_SMOKE_DB')

  if db_name and db_name ~= '' then
    local db_port = tonumber(getenv('OPHAL_SMOKE_DB_PORT') or '')
    local db_host = getenv('OPHAL_SMOKE_DB_HOST')
    local db_user = getenv('OPHAL_SMOKE_DB_USER')
    local db_pass = getenv('OPHAL_SMOKE_DB_PASS')

    settings.db = {
      default = {
        driver = getenv('OPHAL_SMOKE_DB_DRIVER') or 'sqlite3',
        database = db_name,
        host = db_host ~= '' and db_host or nil,
        port = db_port,
        username = db_user ~= '' and db_user or nil,
        password = db_pass ~= '' and db_pass or nil,
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
env OPHAL_SMOKE_DB_DRIVER;
env OPHAL_SMOKE_DB_HOST;
env OPHAL_SMOKE_DB_PORT;
env OPHAL_SMOKE_DB_USER;
env OPHAL_SMOKE_DB_PASS;
env OPHAL_SMOKE_FILES;
env OPHAL_SMOKE_SESSIONS;
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

    # Small on purpose, so a modest test body is enough to make nginx buffer to
    # disk. That is the state the upload fast path is about: the bytes are
    # already on the filesystem and only need a name.
    client_body_buffer_size 1k;

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
      try_files \$uri /__ophal_index__\$is_args\$args;
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

  LAST_SCENARIO='database_seed'
  set +e
  output=$(db_run_cli "$ROOT/tests/smoke/seed_database.lua")
  status=$?
  set -e
  LAST_OUTPUT=$output
  LAST_STATUS=$status
  [[ $status -eq 0 ]] || fail 'database seed failed'

  SEED_CONTENT_TITLE=$(extract_marker 'SEED_CONTENT_TITLE')
  SEED_CONTENT_BODY=$(extract_marker 'SEED_CONTENT_BODY')
  SEED_SECOND_TITLE=$(extract_marker 'SEED_SECOND_TITLE')
  SEED_UNPROMOTED_TITLE=$(extract_marker 'SEED_UNPROMOTED_TITLE')
  SEED_PAGER_TAIL_TITLE=$(extract_marker 'SEED_PAGER_TAIL_TITLE')
  SEED_TAG_NAME=$(extract_marker 'SEED_TAG_NAME')
  SEED_ALIAS=$(extract_marker 'SEED_ALIAS')
  SEED_AUTHOR_NAME=$(extract_marker 'SEED_AUTHOR_NAME')
  SEED_AUTHOR_PASS=$(extract_marker 'SEED_AUTHOR_PASS')

  [[ -n "$SEED_CONTENT_TITLE" && -n "$SEED_TAG_NAME" && -n "$SEED_ALIAS" &&
     -n "$SEED_AUTHOR_NAME" && -n "$SEED_AUTHOR_PASS" &&
     -n "$SEED_PAGER_TAIL_TITLE" ]] ||
    fail 'database seed did not report its fixtures'

  LAST_SCENARIO='database_migrate'
  set +e
  output=$(db_run_cli "$ROOT/ophal" migrate apply)
  status=$?
  set -e
  LAST_OUTPUT=$output
  LAST_STATUS=$status
  [[ $status -eq 0 ]] || fail 'ophal migrate apply failed'
  report_ok database_seed
}

start_db_openresty() {
  local output line
  local -a run_env

  run_env=()
  while IFS= read -r line; do
    run_env+=("$line")
  done < <(db_profile_env)

  set +e
  output=$(env "${run_env[@]}" \
    openresty -t -p "$SMOKE_DB_PREFIX" -c "$SMOKE_DB_CONF" 2>&1)
  LAST_STATUS=$?
  set -e
  LAST_OUTPUT=$output
  [[ "$LAST_STATUS" -eq 0 ]] ||
    fail "openresty config test failed for the $SMOKE_DB_BACKEND profile"

  env "${run_env[@]}" openresty -p "$SMOKE_DB_PREFIX" -c "$SMOKE_DB_CONF"
  SMOKE_DB_PREFIXES+=("$SMOKE_DB_PREFIX")
  SMOKE_DB_CONFS+=("$SMOKE_DB_CONF")

  for _ in $(seq 1 50); do
    if port_ready "$SMOKE_DB_PORT"; then
      return 0
    fi
    sleep 0.1
  done

  fail "the $SMOKE_DB_BACKEND openresty instance did not become ready"
}

# Runs the injection probe against this profile's backend.
#
# Folded into the profiles by stage 8.7 so it runs on every backend on every
# run, which is what the plan asked for: until now it was a thing somebody
# remembered. It runs last in a profile and against the lab's own
# `ophal_bench` database rather than the measured one, because it creates and
# drops a canary table and a measured database has budgets pinned on it.
#
# The probe asserts its own per-backend assertion count, so a probe that
# stopped early is a failure rather than a smaller number nobody was reading.
db_injection_probe() {
  local output status label
  local -a probe_env

  case "$SMOKE_DB_BACKEND" in
    sqlite3) label=SQLite ;;
    postgresql) label=PostgreSQL ;;
    mysql) label=MySQL ;;
    *) fail "no injection probe label for the $SMOKE_DB_BACKEND backend" ;;
  esac

  probe_env=(
    "LUA_PATH=$VENDOR_LUA_PATH"
    "LUA_CPATH=$VENDOR_LUA_CPATH"
    "OPHAL_PROBE_BACKEND=$label"
    "OPHAL_BENCH_SQLITE=$SMOKE_DB_WORK/injection.sqlite"
    "OPHAL_BENCH_PG_HOST=$BACKEND_PG_HOST"
    "OPHAL_BENCH_PG_PORT=$BACKEND_PG_PORT"
    "OPHAL_BENCH_PG_USER=$BACKEND_PG_USER"
    "OPHAL_BENCH_PG_PASS=$BACKEND_PG_PASS"
  )
  if [[ -n "$VENDOR_LD_LIB_DIR" ]]; then
    probe_env+=("LD_LIBRARY_PATH=$VENDOR_LD_LIB_DIR${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}")
  fi

  LAST_SCENARIO="db_injection_probe"
  set +e
  output=$(cd "$ROOT" && env "${probe_env[@]}" resty -c 512 \
    tests/bench/injection_probe.lua 2>&1)
  status=$?
  set -e
  LAST_OUTPUT=$output
  LAST_STATUS=$status

  [[ $status -eq 0 ]] || fail "the injection probe failed on $SMOKE_DB_BACKEND"
  assert_contains '0 failed'
}

# Stopped between profiles rather than left running: each holds a worker, a
# connection pool and a lua_shared_dict, and the next profile has to warm its
# own caches from cold for its budgets to mean what the previous one's did.
stop_db_openresty() {
  openresty -p "$SMOKE_DB_PREFIX" -c "$SMOKE_DB_CONF" -s stop >/dev/null 2>&1 || true
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

#[[ Every scenario that passes is counted, and the total is pinned below.

# Without this the suite reports success for whatever it happened to run. A
# deleted `run_request` and its assertions, a block dropped in a bad merge, or a
# scenario made unreachable by an early branch all shrink coverage in a way that
# looks exactly like a clean run -- the whole output is `ok` lines and a final
# "all scenarios passed", and nothing in it says how many there should have
# been. Since stage 8.7 there is a database profile per backend -- lists that
# have to stay in step, where a profile quietly running half its scenarios is
# exactly what "it passes on PostgreSQL too" would otherwise mean.
#[[ No response may carry a Lua source path, and this is checked everywhere.

# A handler that raises is caught by `route_execute_callback`'s pcall, which
# turns the raise into a string -- and a Lua error string begins with the source
# file and line it was raised at. `theme.json` renders that string into the
# response body, so a raise anywhere in a service became an absolute filesystem
# path on the wire. `GET /comment/save` was the live instance: a bodyless
# request reached `dkjson.decode(nil, ...)`, which raises, and the answer was
# HTTP 200 carrying `.../dkjson.lua:403`.
#
# Fixing the one service that reached it would leave the class open, so the
# check is here rather than in a scenario: every scenario that reports success
# has its last response scanned, and a leak fails the scenario that produced it
# by name. A body that legitimately needs to name a Lua file would have to say
# so, which is the point.
assert_no_source_path() {
  local name=$1

  # Only an HTTP response, which is what the concern is about. Some scenarios
  # leave a harness program's own output in `LAST_OUTPUT` -- the injection probe
  # reports its assertions with file and line, as it should.
  printf '%s\n' "$LAST_OUTPUT" | head -1 | grep -Eq '^HTTP/1\.[01] ' || return 0

  if printf '%s\n' "$LAST_OUTPUT" | grep -Eq '[A-Za-z0-9_/.-]+\.lua:[0-9]+'; then
    fail "$name: response carries a Lua source path: $(printf '%s\n' "$LAST_OUTPUT" | grep -Eo '[A-Za-z0-9_/.-]+\.lua:[0-9]+' | head -1)"
  fi
}

#[[ A theme or template failure must never reach the body.
#
# `theme_execute()` and `theme_render()` returned their error string, and a
# returned string is rendered -- so a missing theme function or an unreadable
# template became page content at HTTP 200. `assert_no_source_path` could not
# see either: `pcall(nil, arg)` raises "attempt to call a nil value" with no
# location, and a template error names a `.tpl.html` path rather than a `.lua`
# one.
#
# Both now answer 500 with the detail in the error log. This is here for the
# reason `assert_no_source_path` is here: fixing the four `return` sites closes
# those sites, and only a guard over every response closes the class -- which
# is how that one found `modules/lorem_ipsum` on its first run, a defect it was
# not written for.
assert_no_theme_error() {
  local name=$1

  printf '%s\n' "$LAST_OUTPUT" | head -1 | grep -Eq '^HTTP/1\.[01] ' || return 0

  if printf '%s\n' "$LAST_OUTPUT" | grep -Eq "theme function [A-Za-z0-9_.]+: '"; then
    fail "$name: response carries a rendered theme error: $(printf '%s\n' "$LAST_OUTPUT" | grep -Eo "theme function [A-Za-z0-9_.]+: '[^']*'" | head -1)"
  fi

  if printf '%s\n' "$LAST_OUTPUT" | grep -Eq "template '[^']+\.tpl\.[a-z]+':"; then
    fail "$name: response carries a rendered template error: $(printf '%s\n' "$LAST_OUTPUT" | grep -Eo "template '[^']+':[^<]*" | head -1)"
  fi
}

report_ok() {
  assert_no_source_path "$1"
  assert_no_theme_error "$1"

  SCENARIO_COUNT=$((SCENARIO_COUNT + 1))
  PROFILE_COUNT=$((PROFILE_COUNT + 1))

  if [[ -n "$PROFILE_LABEL" ]]; then
    printf 'ok [%s] %s\n' "$PROFILE_LABEL" "$1"
  else
    printf 'ok %s\n' "$1"
  fi
}

# The number of scenarios this suite is expected to run, in two parts.
#
# Each goes up when a scenario is added, which is a deliberate edit visible in
# the diff -- that is the point, not an inconvenience. Neither should ever go
# down without the reason being recorded alongside it, the same as a query
# budget moving.
#
# The split is what makes the per-backend profiles checkable. The database
# scenarios are one sourced file run once per backend, so the *same* number has
# to come back from each; a profile that ran fewer would otherwise disappear
# into a single global total, which is the failure the count exists to catch.
EXPECTED_BASE_SCENARIOS=32
EXPECTED_DB_SCENARIOS=108
SCENARIO_COUNT=0

# Reset per profile by `db_profile_begin`; the label prefixes each `ok` line so
# a failure names the backend it happened on.
PROFILE_COUNT=0
PROFILE_LABEL=''
BUDGETS_CLOSED=''
DB_PROFILES_RUN=0
DB_PROFILES_RAN=''
DB_PROFILES_SKIPPED=''

check_dependencies
check_openresty
prepare_tree
start_openresty

#[[ The JSON backend the worker resolved, which the fallback would hide.

# `includes/json.lua` answers the same values through `dkjson` as through
# `cjson`, so a worker demoted to the fallback passes every other assertion in
# this suite and is about nine times slower encoding a service response. This is
# in the base profile because it is a property of the runtime rather than of a
# database.
run_request json_backend "$BASE_URL/__smoke__?scenario=json_backend"
assert_status_zero
assert_regex '^HTTP/1\.[01] 200'
assert_contains 'SMOKE_JSON_BACKEND=cjson'
report_ok json_backend

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

# The traversal, refused. `files_path` sits under the document root that
# nginx.ophal.conf serves static extensions from directly, so an unchecked
# `name` here is an arbitrary write into the served tree for anyone holding
# `upload files` -- a different privilege from the one that permission grants.
# 400 rather than 401: the caller was authenticated and authorised, they just
# asked for something that is not a filename.
escape_target="$SMOKE_ROOT/escaped.html"
rm -f "$escape_target"
run_request file_merge_rejects_traversal \
  -c "$upload_cookie" -b "$upload_cookie" \
  -X POST \
  -H "X-CSRF-Token: $upload_token" \
  "$BASE_URL/__smoke__?scenario=file_merge_chunks&name=../escaped.html&id=$upload_id&size=11&index=1"
assert_status_zero
assert_regex '^HTTP/1\.[01] 400'
assert_contains 'SMOKE_MERGE_SUCCESS=false'
assert_contains 'SMOKE_MERGE_ERROR=Invalid name.'
if [[ -e "$escape_target" ]]; then
  fail "traversal wrote outside files_path: $escape_target"
fi
report_ok file_merge_rejects_traversal

# The same check on the chunk endpoint, where the upload id is the segment that
# reaches a path.
run_request file_upload_rejects_traversal \
  -c "$upload_cookie" -b "$upload_cookie" \
  -X POST \
  -H "X-CSRF-Token: $upload_token" \
  --data 'alpha=part-' \
  "$BASE_URL/__smoke__?scenario=file_upload_chunk&name=$upload_name&id=../../escape&index=0"
assert_status_zero
assert_regex '^HTTP/1\.[01] 400'
assert_contains 'SMOKE_UPLOAD_SUCCESS=false'
assert_contains 'SMOKE_UPLOAD_ERROR=Invalid id.'
report_ok file_upload_rejects_traversal

# A chunk index is a path segment too, so "looks numeric" is not the test.
run_request file_upload_rejects_bad_index \
  -c "$upload_cookie" -b "$upload_cookie" \
  -X POST \
  -H "X-CSRF-Token: $upload_token" \
  --data 'alpha=part-' \
  "$BASE_URL/__smoke__?scenario=file_upload_chunk&name=$upload_name&id=$upload_id&index=1.5"
assert_status_zero
assert_regex '^HTTP/1\.[01] 400'
assert_contains 'SMOKE_UPLOAD_ERROR=Invalid index.'
report_ok file_upload_rejects_bad_index

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

# persistent_interleave: request state must still belong to its own request
# after the coroutine yields. One worker, one Lua VM, two clients in flight at
# once. Request A parks in `ngx.sleep`; request B is sent during that sleep and
# runs `ophal_request_reset()` -- which rewrites `_GET`, `ophal.session`,
# `ophal.cookies` and `base` -- before A resumes.
#
# This is not a cosocket test and it needs no database. `ngx.sleep` is standing
# in for any yield, which is what every query becomes once the driver is
# non-blocking. Until then a request runs start to finish without ever giving
# the worker up, which is the only reason worker-global request state has
# worked at all.
interleave_a="$SMOKE_ROOT/interleave-a.txt"
interleave_b="$SMOKE_ROOT/interleave-b.txt"
cookie_interleave_a="$SMOKE_ROOT/cookie-interleave-a.txt"
cookie_interleave_b="$SMOKE_ROOT/cookie-interleave-b.txt"

curl -sS -i --max-time 10 -H 'Host: example.com' \
  -c "$cookie_interleave_a" -b "$cookie_interleave_a" \
  "$PERSISTENT_URL/__smoke__?scenario=interleave&tag=alpha&delay=0.5" \
  >"$interleave_a" 2>&1 &
interleave_pid=$!

# Long enough for A to have reached its sleep, short enough to be well inside
# it. The overlap is asserted from the timestamps below rather than assumed
# from this number.
sleep 0.15

curl -sS -i --max-time 10 -H 'Host: example.com' \
  -c "$cookie_interleave_b" -b "$cookie_interleave_b" \
  "$PERSISTENT_URL/__smoke__?scenario=interleave&tag=beta&delay=0" \
  >"$interleave_b" 2>&1
wait "$interleave_pid"

LAST_SCENARIO=persistent_interleave
LAST_STATUS=0

LAST_OUTPUT=$(cat "$interleave_b")
assert_regex '^HTTP/1\.[01] 200'
assert_contains 'SMOKE_TAG=beta'
interleave_b_start=$(extract_marker 'SMOKE_START')
interleave_b_end=$(extract_marker 'SMOKE_END')
interleave_b_session=$(extract_marker 'SMOKE_SESSION_BEFORE')

LAST_OUTPUT=$(cat "$interleave_a")
assert_regex '^HTTP/1\.[01] 200'
assert_contains 'SMOKE_TAG=alpha'
interleave_a_start=$(extract_marker 'SMOKE_START')
interleave_a_end=$(extract_marker 'SMOKE_END')

# B has to have started after A and finished before A did, or the two never
# shared the worker and the assertions below prove nothing.
awk -v a_start="$interleave_a_start" -v a_end="$interleave_a_end" \
  -v b_start="$interleave_b_start" -v b_end="$interleave_b_end" \
  'BEGIN { exit !(b_start >= a_start && b_end <= a_end) }' ||
  fail "requests did not overlap: A $interleave_a_start-$interleave_a_end, B $interleave_b_start-$interleave_b_end"

# A's own query argument, before and after the yield.
assert_contains 'SMOKE_GET_BEFORE=alpha'
assert_contains 'SMOKE_GET_AFTER=alpha'

# Page state and the accumulators: A's own tag, and no trace of B's. `ophal`,
# `get_head()` and `get_js()` are three separate mechanisms and each is asserted
# rather than assumed from the one beside it.
assert_contains 'SMOKE_TITLE_AFTER=alpha'
assert_contains 'interleave:alpha -->'
assert_not_contains 'interleave:beta -->'
assert_contains '/* interleave:alpha */'
assert_not_contains '/* interleave:beta */'

# A's own session, before and after the yield. Distinct cookie jars, so B's id
# is a different string; reading it here means A resumed holding B's session.
interleave_a_session_before=$(extract_marker 'SMOKE_SESSION_BEFORE')
interleave_a_session_after=$(extract_marker 'SMOKE_SESSION_AFTER')
[[ -n "$interleave_a_session_before" ]] ||
  fail 'no session id reported for the interleaved request'
[[ "$interleave_a_session_before" == "$interleave_a_session_after" ]] ||
  fail "session changed across the yield: $interleave_a_session_before -> $interleave_a_session_after"
[[ "$interleave_a_session_after" != "$interleave_b_session" ]] ||
  fail 'the interleaved request resumed holding the other request session'
# The session's *contents*, not only its id. Both requests materialize a lazy
# session mid-flight, so this is the value A wrote before parking.
assert_contains 'SMOKE_SESSION_TAG_AFTER=alpha'
report_ok persistent_interleave

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

# The filesystem counterpart of `read_db_stats`, and cumulative in the same way:
# the difference between two probes is what the requests between them cost.
#[[ The filesystem counters, read from the non-bootstrapping probe.
#
# Three buckets and seven ops, walked rather than spelled out. They used to be
# written one variable per term, which is why adding `rename` for the session
# store touched nine call sites and adding `stat` for the render bucket would
# have touched them again. `includes/fs/stats.lua` names its ops in one list;
# so does this.
FS_BUCKETS=(media session render)
FS_OPS=(stat open read write rename remove bytes)

fs_marker_prefix() {
  case "$1" in
    media) printf 'SMOKE_FS' ;;
    session) printf 'SMOKE_FS_SESSION' ;;
    render) printf 'SMOKE_FS_RENDER' ;;
    *) fail "fs stats: unknown bucket '$1'" ;;
  esac
}

# The variable-name stem for a bucket: `FS_M_OPEN`, `FS_S_OPEN`, `FS_R_STAT`.
fs_var_prefix() {
  case "$1" in
    media) printf 'FS_M' ;;
    session) printf 'FS_S' ;;
    render) printf 'FS_R' ;;
    *) fail "fs stats: unknown bucket '$1'" ;;
  esac
}

read_fs_stats() {
  local saved_scenario=$LAST_SCENARIO
  local bucket op marker value

  run_request fs_stats_probe "$DB_URL/__smoke__?scenario=fs_stats"

  for bucket in "${FS_BUCKETS[@]}"; do
    for op in "${FS_OPS[@]}"; do
      marker="$(fs_marker_prefix "$bucket")_$(printf '%s' "$op" | tr '[:lower:]' '[:upper:]')"
      value=$(extract_marker "$marker")
      [[ -n "$value" ]] ||
        fail "filesystem stats probe reported no $marker"
      printf -v "TOTAL_$(fs_var_prefix "$bucket")_$(printf '%s' "$op" | tr '[:lower:]' '[:upper:]')" '%s' "$value"
    done
  done

  LAST_SCENARIO=$saved_scenario
}

measure_fs_request() {
  local name=$1
  shift
  local bucket op var total_var
  local measured_output measured_status
  declare -A before=()

  read_fs_stats
  for bucket in "${FS_BUCKETS[@]}"; do
    for op in "${FS_OPS[@]}"; do
      total_var="TOTAL_$(fs_var_prefix "$bucket")_$(printf '%s' "$op" | tr '[:lower:]' '[:upper:]')"
      before["$bucket:$op"]=${!total_var}
    done
  done

  run_request "$name" "$@"
  measured_output=$LAST_OUTPUT
  measured_status=$LAST_STATUS

  read_fs_stats
  for bucket in "${FS_BUCKETS[@]}"; do
    for op in "${FS_OPS[@]}"; do
      var="$(fs_var_prefix "$bucket")_$(printf '%s' "$op" | tr '[:lower:]' '[:upper:]')"
      total_var="TOTAL_$var"
      printf -v "$var" '%s' "$(( ${!total_var} - ${before["$bucket:$op"]} ))"
    done
  done

  LAST_OUTPUT=$measured_output
  LAST_STATUS=$measured_status
  LAST_SCENARIO=$name
}

# Formats one bucket's measured terms for a message or an `ok` line.
fs_measured() {
  local bucket=$1 op var out=''

  for op in "${FS_OPS[@]}"; do
    var="$(fs_var_prefix "$bucket")_$(printf '%s' "$op" | tr '[:lower:]' '[:upper:]')"
    out+="$op=${!var} "
  done

  printf '%s' "${out% }"
}

#[[ One filesystem budget helper, taking the bucket and named terms.
#
#   assert_fs_budget media  open=2 write=1 bytes=8
#   assert_fs_budget render stat=6
#
# **An unstated term asserts zero**, which is what keeps a budget a statement
# about absence as well as presence -- the property the positional form had and
# the reason it is worth preserving. What the positional form did not have is
# room to grow: `rename` joined when the session store landed and moved every
# call site, and `stat` would have moved them all again.
#
# The bucket is named at the call site for the reason `includes/fs/stats.lua`
# names it at every `record()` and every `snapshot()`: a media request opens a
# session and renders a page, so a budget that does not say which path it
# describes quietly starts describing three.
assert_fs_budget() {
  local bucket=$1
  shift
  local term op value measured
  declare -A expected=()

  budgets_are_closed

  case "$bucket" in
    media|session|render) ;;
    *) fail "assert_fs_budget: unknown bucket '$bucket'" ;;
  esac

  for op in "${FS_OPS[@]}"; do
    expected["$op"]=0
  done

  for term in "$@"; do
    op=${term%%=*}
    value=${term#*=}
    [[ "$term" == *=* && -n "${expected[$op]+set}" ]] ||
      fail "assert_fs_budget: unknown term '$term' (ops: ${FS_OPS[*]})"
    expected["$op"]=$value
  done

  measured=$(fs_measured "$bucket")

  for op in "${FS_OPS[@]}"; do
    value="$(fs_var_prefix "$bucket")_$(printf '%s' "$op" | tr '[:lower:]' '[:upper:]')"
    [[ "${!value}" -eq "${expected[$op]}" ]] ||
      fail "expected ${expected[$op]} $bucket $op, measured ${!value}
  $bucket: $measured"
  done
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
#[[ Close the budgets. Everything below this line may write.
#
# A pinned budget is a statement about warm caches, and every projection in
# this codebase is versioned by the **unix second** its source last changed --
# so whether a write lands inside the next reader's second is timing. Three
# content-creating scenarios inserted after `db_content_page_after_update` on
# 2026-09-10 moved `db_tag_after_update` from 1 normalized read to 4 by
# invalidating the tag projection it measures warm, and it showed up on MySQL
# only, in one run. A suite that catches that probabilistically does not catch
# it.
#
# So: **a scenario that writes goes below the barrier**, which is where a new
# scenario naturally lands anyway, and a budget asserted below it is refused
# rather than quietly trusted. Moving the barrier down is a deliberate edit
# visible in the diff, the way `EXPECTED_DB_SCENARIOS` is.
#
# Bash cannot see that a scenario writes, so this enforces the half that is
# enforceable. The other half is the sentence above.
budget_barrier() {
  BUDGETS_CLOSED=1
}

budgets_are_closed() {
  [[ -n "$BUDGETS_CLOSED" ]] &&
    fail "$LAST_SCENARIO: a budget is pinned below budget_barrier, where an
  earlier scenario's write may already have moved it. Move the scenario above
  the barrier, or move the barrier below it if the budget is genuinely
  independent of everything between."
  return 0
}

assert_query_budget() {
  local expected_total=$1 expected_normalized=$2 expected_infrastructure=${3:-0}

  budgets_are_closed

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
# ================================================================
# Database profiles: one OpenResty instance per backend, `lua_code_cache on`,
# against a real server.
#
# The unit budget tests measure handlers with the database stubbed. These
# measure whole requests: nginx, bootstrap, routing, theme and the backend.
#
# There is one instance per backend rather than one server block per backend,
# for the reason there has always been two instances: routes are cached per
# worker after the first request, and a worker that served one profile would
# answer the next one's requests from a route table built somewhere else. It is
# also what makes the warm measurements mean anything -- a worker only ever
# serves one profile, so its caches fill the way a real site's do.
#
# The scenario list is `tests/smoke/db_profile.sh`, sourced once per backend, so
# "the same scenarios pass on PostgreSQL" is a fact about one file rather than
# about two lists somebody kept in step by hand.
# ================================================================

# The base count is checked before the first profile rather than only at the
# end. Otherwise a scenario lost up here and a scenario added down there cancel
# out in the total, and the suite reports a number that is right for the wrong
# reason.
if [[ "$SCENARIO_COUNT" -ne "$EXPECTED_BASE_SCENARIOS" ]]; then
  fail "ran $SCENARIO_COUNT scenarios before the database profiles, expected $EXPECTED_BASE_SCENARIOS -- a scenario was added or lost; update EXPECTED_BASE_SCENARIOS deliberately"
fi

# SQLite is a file, so it is always available. A server backend is the vendored
# lab, which a clean checkout does not have -- so it is skipped, loudly and by
# name, and `OPHAL_SMOKE_REQUIRE_BACKENDS=1` turns that skip into a failure for
# a build that is supposed to have one.
db_backend_available() {
  case "$1" in
    sqlite3)
      return 0
      ;;
    postgresql)
      port_ready "$BACKEND_PG_PORT"
      ;;
    mysql)
      port_ready "$BACKEND_MY_PORT"
      ;;
    *)
      return 1
      ;;
  esac
}

db_backend_skip() {
  local backend=$1
  local detail

  case "$backend" in
    postgresql)
      detail="no server is listening on ${BACKEND_PG_HOST}:${BACKEND_PG_PORT}"
      ;;
    mysql)
      detail="no server is listening on ${BACKEND_MY_HOST}:${BACKEND_MY_PORT}"
      ;;
    *)
      detail='it is not available'
      ;;
  esac

  if [[ -n "${OPHAL_SMOKE_REQUIRE_BACKENDS:-}" ]]; then
    fail "the $backend backend is required but $detail"
  fi

  DB_PROFILES_SKIPPED="${DB_PROFILES_SKIPPED}${DB_PROFILES_SKIPPED:+, }$backend"
  printf 'skip database profile %s -- %s; run: bash tests/bench/setup_backends.sh all\n' \
    "$backend" "$detail" >&2
}

# Each profile has to come back with exactly the same number of scenarios as
# every other, because they run the same file. A profile that stopped early
# would otherwise be invisible in a single global total.
db_profile_end() {
  local backend=$SMOKE_DB_BACKEND

  if [[ "$PROFILE_COUNT" -ne "$EXPECTED_DB_SCENARIOS" ]]; then
    fail "the $backend profile ran $PROFILE_COUNT scenarios, expected $EXPECTED_DB_SCENARIOS -- every profile sources the same scenario file, so they cannot differ; update EXPECTED_DB_SCENARIOS deliberately"
  fi

  stop_db_openresty
  PROFILE_LABEL=''
  DB_PROFILES_RUN=$((DB_PROFILES_RUN + 1))
  DB_PROFILES_RAN="${DB_PROFILES_RAN}${DB_PROFILES_RAN:+, }$backend"
}

# `OPHAL_SMOKE_BACKENDS` narrows the run while iterating on a scenario -- one
# profile takes a third of the time three do. It is a development convenience
# and nothing else: unset it runs all three, and the count check below still
# holds the profiles that did run to their full scenario list, so a narrowed run
# cannot pass by running less.
for db_backend in ${OPHAL_SMOKE_BACKENDS:-sqlite3 postgresql mysql}; do
  if ! db_backend_available "$db_backend"; then
    db_backend_skip "$db_backend"
    continue
  fi

  db_profile_begin "$db_backend"
  prepare_db_tree
  seed_database
  start_db_openresty
  . "$ROOT/tests/smoke/db_profile.sh"
  db_profile_end
done

if [[ "$DB_PROFILES_RUN" -eq 0 ]]; then
  fail 'no database profile ran'
fi

expected_total=$((EXPECTED_BASE_SCENARIOS + DB_PROFILES_RUN * EXPECTED_DB_SCENARIOS))

if [[ "$SCENARIO_COUNT" -ne "$expected_total" ]]; then
  fail "ran $SCENARIO_COUNT scenarios, expected $expected_total ($EXPECTED_BASE_SCENARIOS base + $DB_PROFILES_RUN x $EXPECTED_DB_SCENARIOS database) -- a scenario was added or lost; update the expected counts deliberately"
fi

printf 'all %d openresty smoke scenarios passed (%d database profile(s): %s)\n' \
  "$SCENARIO_COUNT" "$DB_PROFILES_RUN" "$DB_PROFILES_RAN"

if [[ -n "$DB_PROFILES_SKIPPED" ]]; then
  printf 'skipped database profile(s): %s\n' "$DB_PROFILES_SKIPPED" >&2
fi
