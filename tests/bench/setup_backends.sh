#!/usr/bin/env bash
#
# Vendors the database backends and the candidate Lua drivers the query-layer
# benchmark measures, and runs the clusters unprivileged.
#
# Nothing here needs root. `apt-get download` plus `dpkg-deb -x` into a local
# prefix is the same pattern `tests/smoke/setup_vendor_runtime.sh` already uses;
# PostgreSQL refuses to run as root anyway, so unprivileged is its supported
# shape, and MariaDB is happy with an explicit --datadir.
#
# The apt lists in this workspace can be older than the pool, so the versioned
# packages are fetched from the pool directory by name rather than through
# `apt-get download`, which resolves to whatever version the stale list names
# and then 404s.
#
#   bash tests/bench/setup_backends.sh install   # download and unpack
#   bash tests/bench/setup_backends.sh init      # create the clusters
#   bash tests/bench/setup_backends.sh start     # start both
#   bash tests/bench/setup_backends.sh stop      # stop both
#   bash tests/bench/setup_backends.sh status
#
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
BACKENDS="$ROOT/tests/smoke/vendor/backends"
DEBS="$BACKENDS/debs"
PG_PREFIX="$BACKENDS/pg"
MY_PREFIX="$BACKENDS/mysql"
LUA_PREFIX="$BACKENDS/lua"
RUN="$BACKENDS/run"

PG_VERSION="${OPHAL_BENCH_PG_VERSION:-16.15-0ubuntu0.24.04.1}"
PG_MAJOR="${PG_VERSION%%.*}"
MY_VERSION="${OPHAL_BENCH_MY_VERSION:-10.11.14-0ubuntu0.24.04.1}"
MYSQLCLIENT_VERSION="${OPHAL_BENCH_MYSQLCLIENT_VERSION:-8.0.46-0ubuntu0.24.04.4}"
PGMOON_VERSION="${OPHAL_BENCH_PGMOON_VERSION:-1.18.0}"

PG_PORT="${OPHAL_BENCH_PG_PORT:-15432}"
MY_PORT="${OPHAL_BENCH_MY_PORT:-13306}"
DB_USER="${OPHAL_BENCH_DB_USER:-ophal}"
DB_PASS="${OPHAL_BENCH_DB_PASS:-ophal}"
DB_NAME="${OPHAL_BENCH_DB_NAME:-ophal_bench}"

PG_POOL='http://archive.ubuntu.com/ubuntu/pool/main/p/postgresql-16'
MY_POOL='http://archive.ubuntu.com/ubuntu/pool/universe/m/mariadb'
MYSQL_POOL='http://archive.ubuntu.com/ubuntu/pool/main/m/mysql-8.0'
SQLITE_POOL='http://archive.ubuntu.com/ubuntu/pool/main/s/sqlite3'

PG_BIN="$PG_PREFIX/usr/lib/postgresql/$PG_MAJOR/bin"
PG_DATA="$RUN/pgdata"
PG_SOCK="$RUN/pgsock"
MY_DATA="$RUN/mydata"
MY_SOCK="$RUN/mysql.sock"

pg_env() {
  export LD_LIBRARY_PATH="$PG_PREFIX/usr/lib/x86_64-linux-gnu:$PG_PREFIX/usr/lib/postgresql/$PG_MAJOR/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
  export LC_ALL=C
}

my_env() {
  export LD_LIBRARY_PATH="$MY_PREFIX/usr/lib/x86_64-linux-gnu${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
}

fetch() {
  local url=$1 target=$2

  if [[ -s "$target" ]]; then
    return 0
  fi

  printf '  fetching %s\n' "$(basename "$target")"
  curl -fsSL --retry 3 -o "$target" "$url"
}

# lsqlite3 has no Ubuntu package and there is no LuaRocks here, so it is
# compiled from source against the system sqlite. Two details are needed:
# `luaL_reg` was renamed `luaL_Reg` long after this source was written, and the
# sqlite3 shared object has to be named in full because libsqlite3-dev's
# development symlink is not on the loader path.
build_lsqlite3() {
  local target="$LUA_PREFIX/usr/lib/x86_64-linux-gnu/lua/5.1/lsqlite3.so"
  local headers="$DEBS/sqlite-dev"
  local src="$DEBS/lsqlite3-master"
  local dev

  if [[ -f "$target" ]]; then
    return 0
  fi

  if ! command -v gcc >/dev/null 2>&1; then
    printf '  no gcc: skipping lsqlite3\n' >&2
    return 0
  fi

  if [[ ! -f "$headers/usr/include/sqlite3.h" ]]; then
    dev=$(curl -fsSL "$SQLITE_POOL/" |
      grep -o 'href="libsqlite3-dev_[^"]*_amd64\.deb"' |
      sed 's/href="//;s/"//' | sort -V | tail -1)
    [[ -n "$dev" ]] || { printf '  no libsqlite3-dev in the pool: skipping lsqlite3\n' >&2; return 0; }
    fetch "$SQLITE_POOL/$dev" "$DEBS/$dev"
    mkdir -p "$headers"
    dpkg-deb -x "$DEBS/$dev" "$headers"
  fi

  if [[ ! -f "$src/lsqlite3.c" ]]; then
    fetch 'https://github.com/LuaDist/lsqlite3/archive/refs/heads/master.tar.gz' \
      "$DEBS/lsqlite3.tar.gz"
    tar xzf "$DEBS/lsqlite3.tar.gz" -C "$DEBS"
  fi

  mkdir -p "$(dirname "$target")"
  gcc -O2 -fPIC -shared -DluaL_reg=luaL_Reg -o "$target" "$src/lsqlite3.c" \
    -I "$headers/usr/include" \
    -I /usr/local/openresty/luajit/include/luajit-2.1 \
    /usr/lib/x86_64-linux-gnu/libsqlite3.so.0
  printf '  built lsqlite3\n'
}

install_backends() {
  mkdir -p "$DEBS" "$PG_PREFIX" "$MY_PREFIX" "$LUA_PREFIX"

  local p
  for p in libpq5 postgresql-$PG_MAJOR postgresql-client-$PG_MAJOR; do
    fetch "$PG_POOL/${p}_${PG_VERSION}_amd64.deb" "$DEBS/${p}_${PG_VERSION}_amd64.deb"
  done

  fetch "$MY_POOL/mariadb-common_${MY_VERSION}_all.deb" "$DEBS/mariadb-common_${MY_VERSION}_all.deb"

  # LuaDBI's and LuaSQL's MySQL bindings link Oracle's client library, not
  # MariaDB's, so the server being MariaDB does not spare us this one.
  fetch "$MYSQL_POOL/libmysqlclient21_${MYSQLCLIENT_VERSION}_amd64.deb" \
    "$DEBS/libmysqlclient21_${MYSQLCLIENT_VERSION}_amd64.deb"
  for p in mariadb-server mariadb-server-core mariadb-client mariadb-client-core libmariadb3; do
    fetch "$MY_POOL/${p}_${MY_VERSION}_amd64.deb" "$DEBS/${p}_${MY_VERSION}_amd64.deb"
  done

  # Packages whose archive version the local lists still agree with.
  ( cd "$DEBS" && apt-get download \
      postgresql-common postgresql-client-common \
      mysql-common liburing2 libnuma1 libncurses6 \
      lua-dbi-common lua-dbi-postgresql lua-dbi-mysql lua-dbi-sqlite3 \
      lua-sql-postgres lua-sql-mysql lua-sql-sqlite3 \
      lua-bitop >/dev/null )

  local deb
  for deb in "$DEBS"/*postgresql*.deb "$DEBS"/libpq5*.deb; do
    case "$deb" in *lua-dbi*|*lua-sql*) continue;; esac
    dpkg-deb -x "$deb" "$PG_PREFIX"
  done
  for deb in "$DEBS"/mariadb*.deb "$DEBS"/mysql-common*.deb "$DEBS"/liburing2*.deb \
             "$DEBS"/libnuma1*.deb "$DEBS"/libncurses6*.deb; do
    dpkg-deb -x "$deb" "$MY_PREFIX"
  done
  for deb in "$DEBS"/lua-*.deb "$DEBS"/libmysqlclient21*.deb; do
    dpkg-deb -x "$deb" "$LUA_PREFIX"
  done

  # pgmoon is pure Lua, so it is a tarball rather than a rock: there is no
  # LuaRocks in this workspace and nothing here needs compiling.
  mkdir -p "$LUA_PREFIX/share"
  if [[ ! -f "$LUA_PREFIX/share/pgmoon/init.lua" ]]; then
    fetch "https://github.com/leafo/pgmoon/archive/refs/tags/v${PGMOON_VERSION}.tar.gz" \
      "$DEBS/pgmoon-${PGMOON_VERSION}.tar.gz"
    tar xzf "$DEBS/pgmoon-${PGMOON_VERSION}.tar.gz" -C "$DEBS"
    cp -R "$DEBS/pgmoon-${PGMOON_VERSION}/pgmoon" "$LUA_PREFIX/share/"
  fi

  build_lsqlite3

  printf 'backends unpacked under %s\n' "$BACKENDS"
}

init_backends() {
  mkdir -p "$RUN" "$PG_SOCK"

  if [[ ! -f "$PG_DATA/PG_VERSION" ]]; then
    pg_env
    "$PG_BIN/initdb" -D "$PG_DATA" -U "$DB_USER" --auth=trust --no-sync -E UTF8 >/dev/null
    printf 'initialised postgres cluster at %s\n' "$PG_DATA"
  fi

  if [[ ! -d "$MY_DATA/mysql" ]]; then
    my_env
    mkdir -p "$MY_DATA"
    "$MY_PREFIX/usr/bin/mariadb-install-db" \
      --basedir="$MY_PREFIX/usr" --datadir="$MY_DATA" --user="$(id -un)" \
      --auth-root-authentication-method=normal --skip-test-db >/dev/null
    printf 'initialised mariadb datadir at %s\n' "$MY_DATA"
  fi
}

start_backends() {
  pg_env
  if ! "$PG_BIN/pg_isready" -h 127.0.0.1 -p "$PG_PORT" >/dev/null 2>&1; then
    "$PG_BIN/pg_ctl" -D "$PG_DATA" -l "$PG_DATA/server.log" \
      -o "-p $PG_PORT -k $PG_SOCK -c listen_addresses=127.0.0.1" -w start >/dev/null
  fi
  "$PG_BIN/psql" -h 127.0.0.1 -p "$PG_PORT" -U "$DB_USER" -d postgres -tAc \
    "SELECT 1 FROM pg_database WHERE datname = '$DB_NAME'" | grep -q 1 ||
    "$PG_BIN/createdb" -h 127.0.0.1 -p "$PG_PORT" -U "$DB_USER" "$DB_NAME"

  my_env
  if ! "$MY_PREFIX/usr/bin/mariadb-admin" --protocol=TCP -h 127.0.0.1 -P "$MY_PORT" -u root ping >/dev/null 2>&1; then
    nohup "$MY_PREFIX/usr/sbin/mariadbd" --no-defaults \
      --basedir="$MY_PREFIX/usr" --datadir="$MY_DATA" --socket="$MY_SOCK" \
      --port="$MY_PORT" --bind-address=127.0.0.1 --pid-file="$MY_DATA/mariadb.pid" \
      --log-error="$MY_DATA/error.log" >"$MY_DATA/stdout.log" 2>&1 &
    local waited=0
    until "$MY_PREFIX/usr/bin/mariadb-admin" --protocol=TCP -h 127.0.0.1 -P "$MY_PORT" -u root ping >/dev/null 2>&1; do
      waited=$((waited + 1))
      [[ $waited -lt 60 ]] || { printf 'mariadb did not start; see %s\n' "$MY_DATA/error.log" >&2; exit 1; }
      sleep 0.5
    done
  fi

  # `lua-resty-mysql` speaks mysql_native_password only, so the bench user is
  # created with it explicitly rather than left on the server default.
  "$MY_PREFIX/usr/bin/mariadb" --protocol=TCP -h 127.0.0.1 -P "$MY_PORT" -u root -e "
    CREATE DATABASE IF NOT EXISTS $DB_NAME;
    CREATE USER IF NOT EXISTS '$DB_USER'@'%' IDENTIFIED VIA mysql_native_password USING PASSWORD('$DB_PASS');
    GRANT ALL ON $DB_NAME.* TO '$DB_USER'@'%';
    FLUSH PRIVILEGES;" >/dev/null

  printf 'postgres on 127.0.0.1:%s, mariadb on 127.0.0.1:%s\n' "$PG_PORT" "$MY_PORT"
}

stop_backends() {
  pg_env
  if [[ -f "$PG_DATA/postmaster.pid" ]]; then
    "$PG_BIN/pg_ctl" -D "$PG_DATA" -m fast -w stop >/dev/null 2>&1 || true
  fi

  my_env
  if [[ -f "$MY_DATA/mariadb.pid" ]]; then
    "$MY_PREFIX/usr/bin/mariadb-admin" --protocol=TCP -h 127.0.0.1 -P "$MY_PORT" -u root shutdown >/dev/null 2>&1 || true
  fi

  printf 'backends stopped\n'
}

status_backends() {
  pg_env
  "$PG_BIN/pg_isready" -h 127.0.0.1 -p "$PG_PORT" || true
  my_env
  "$MY_PREFIX/usr/bin/mariadb-admin" --protocol=TCP -h 127.0.0.1 -P "$MY_PORT" -u root ping || true
}

case "${1:-}" in
  install) install_backends ;;
  init) init_backends ;;
  start) start_backends ;;
  stop) stop_backends ;;
  status) status_backends ;;
  all) install_backends; init_backends; start_backends ;;
  *) printf 'usage: %s {install|init|start|stop|status|all}\n' "$0" >&2; exit 2 ;;
esac
