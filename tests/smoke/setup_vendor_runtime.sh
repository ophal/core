#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
VENDOR_ROOT="$ROOT/tests/smoke/vendor"
VENDOR_DEBS="$VENDOR_ROOT/debs"
VENDOR_UNPACK="$VENDOR_ROOT/unpack"
VENDOR_SEAWOLF="$VENDOR_ROOT/seawolf"
SEAWOLF_REF="${SEAWOLF_REF:-master}"
PACKAGES=(lua-filesystem lua-lpeg lua-socket lua-dkjson)

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

main() {
  require_command apt
  require_command dpkg-deb
  require_command git

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

  write_uuid_shim

  printf 'smoke vendor runtime prepared under %s\n' "$VENDOR_ROOT"
}

main "$@"
