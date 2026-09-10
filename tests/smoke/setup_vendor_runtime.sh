#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
VENDOR_ROOT="$ROOT/tests/smoke/vendor"
VENDOR_DEBS="$VENDOR_ROOT/debs"
VENDOR_UNPACK="$VENDOR_ROOT/unpack"
VENDOR_SEAWOLF="$VENDOR_ROOT/seawolf"
SEAWOLF_REF="${SEAWOLF_REF:-master}"
# No database binding here: SQLite is lsqlite3, built below, and PostgreSQL and
# MySQL are pgmoon and the bundled `lua-resty-mysql`. LuaDBI is gone.
# `lua-dkjson` is no longer a dependency of Ophal -- `includes/json.lua` is
# cjson, which ships with OpenResty. It stays vendored for one reason:
# `tests/bench/json_bench.lua` is the measurement that chose cjson, and a
# comparison needs both sides of it.
PACKAGES=(lua-filesystem lua-socket lua-dkjson)
LSQLITE_REF="${LSQLITE_REF:-master}"
LSQLITE_TARBALL="https://github.com/LuaDist/lsqlite3/archive/refs/heads/$LSQLITE_REF.tar.gz"
# The headers lsqlite3 compiles against. Taken from the pool directory rather
# than through `apt download`, because the apt lists in this workspace can be
# older than the pool and a versioned fetch 404s -- the same reason
# `tests/bench/setup_backends.sh` fetches its servers by name.
SQLITE_POOL='http://archive.ubuntu.com/ubuntu/pool/main/s/sqlite3'

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    printf 'missing required command: %s\n' "$1" >&2
    exit 1
  }
}

write_uuid_shim() {
  cat > "$VENDOR_ROOT/uuid.lua" <<'LUA'
local M = {}

local function kernel_uuid()
  local fh = io.open('/proc/sys/kernel/random/uuid', 'r')
  if not fh then
    return nil
  end

  local value = fh:read('*l')
  fh:close()
  return value
end

function M.new()
  local value = kernel_uuid()
  assert(value and value ~= '', 'unable to generate uuid')
  return value
end

function M.isvalid(value)
  if type(value) ~= 'string' then
    return false
  end

  return value:match('^[%x][%x][%x][%x][%x][%x][%x][%x]%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$') ~= nil
end

return M
LUA
}

#[[ Build lsqlite3 into the vendored tree.
#
# SQLite is reached through lsqlite3 rather than LuaDBI, because LuaDBI reads
# integer columns with 32-bit precision. A real install takes it from LuaRocks
# (`luarocks install lsqlite3complete`, which links SQLite statically); this
# workspace has no LuaRocks, so it is compiled against the headers apt just
# unpacked. Two details are needed: `luaL_reg` was renamed `luaL_Reg` long after
# this source was written, and the sqlite3 shared object has to be named in full
# because the development symlink is not on the loader path.
#
# It is built against the LuaJIT headers and loads under both `resty` and
# LuaJIT -- one binding for the worker and the command line, both `resty`.
build_lsqlite3() {
  local target="$VENDOR_UNPACK/usr/lib/x86_64-linux-gnu/lua/5.1/lsqlite3.so"
  local src="$VENDOR_DEBS/lsqlite3-$LSQLITE_REF"
  local dev

  if ! command -v gcc >/dev/null 2>&1; then
    printf 'missing required command: gcc (needed to build lsqlite3)\n' >&2
    exit 1
  fi

  dev=$(curl -fsSL "$SQLITE_POOL/" |
    grep -o 'href="libsqlite3-dev_[^"]*_amd64\.deb"' |
    sed 's/href="//;s/"//' | sort -V | tail -1)

  if [[ -z "$dev" ]]; then
    printf 'no libsqlite3-dev in the pool at %s\n' "$SQLITE_POOL" >&2
    exit 1
  fi

  curl -fsSL --retry 3 -o "$VENDOR_DEBS/$dev" "$SQLITE_POOL/$dev"
  dpkg-deb -x "$VENDOR_DEBS/$dev" "$VENDOR_UNPACK"

  curl -fsSL --retry 3 -o "$VENDOR_DEBS/lsqlite3.tar.gz" "$LSQLITE_TARBALL"
  tar xzf "$VENDOR_DEBS/lsqlite3.tar.gz" -C "$VENDOR_DEBS"

  mkdir -p "$(dirname "$target")"
  gcc -O2 -fPIC -shared -DluaL_reg=luaL_Reg -o "$target" "$src/lsqlite3.c" \
    -I "$VENDOR_UNPACK/usr/include" \
    -I /usr/local/openresty/luajit/include/luajit-2.1 \
    /usr/lib/x86_64-linux-gnu/libsqlite3.so.0

  printf '  built lsqlite3\n'
}

main() {
  require_command apt
  require_command dpkg-deb
  require_command git
  require_command curl

  rm -rf "$VENDOR_DEBS" "$VENDOR_UNPACK"
  mkdir -p "$VENDOR_DEBS" "$VENDOR_UNPACK"

  (
    cd "$VENDOR_DEBS"
    apt download "${PACKAGES[@]}"
  )

  for deb in "$VENDOR_DEBS"/*.deb; do
    dpkg-deb -x "$deb" "$VENDOR_UNPACK"
  done

  if [[ -d "$VENDOR_SEAWOLF/.git" ]]; then
    git -C "$VENDOR_SEAWOLF" fetch --depth=1 origin "$SEAWOLF_REF"
    git -C "$VENDOR_SEAWOLF" checkout --detach FETCH_HEAD
  else
    git clone --depth=1 --branch "$SEAWOLF_REF" https://github.com/ophal/seawolf.git "$VENDOR_SEAWOLF"
  fi

  build_lsqlite3
  write_uuid_shim

  printf 'smoke vendor runtime prepared under %s\n' "$VENDOR_ROOT"
}

main "$@"
