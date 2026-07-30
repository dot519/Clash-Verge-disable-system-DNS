#!/bin/bash
# Prevent Clash Verge Rev from writing a static macOS DNS server at TUN startup.
# Usage: ./clash-verge-disable-system-dns.sh {install|status|restore} [app-path]

set -euo pipefail

readonly EXPECTED_BUNDLE_ID="io.github.clash-verge-rev.clash-verge-rev"
readonly DEFAULT_APP="/Applications/Clash Verge.app"

action="${1:-}"
app_path="${2:-$DEFAULT_APP}"

usage() {
  echo "Usage: $0 {install|status|restore} [app-path]" >&2
  exit 64
}

fail() {
  echo "Error: $*" >&2
  exit 1
}

require_macos() {
  [ "$(uname -s)" = "Darwin" ] || fail "This script supports macOS only."
  command -v plutil >/dev/null || fail "plutil is required."
  command -v codesign >/dev/null || fail "codesign is required."
}

resolve_app() {
  [ -d "$app_path" ] || fail "App bundle not found: $app_path"
  app_path="$(cd "$app_path/.." && pwd -P)/$(basename "$app_path")"
  [ -f "$app_path/Contents/Info.plist" ] || fail "Not a macOS app bundle: $app_path"

  local bundle_id
  bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app_path/Contents/Info.plist" 2>/dev/null || true)"
  [ "$bundle_id" = "$EXPECTED_BUNDLE_ID" ] || fail "Refusing unexpected bundle id: ${bundle_id:-unknown}"
}

target_script() {
  printf '%s\n' "$app_path/Contents/Resources/resources/set_dns.sh"
}

backup_script() {
  printf '%s\n' "$(target_script).before-disable-system-dns"
}

is_patched() {
  grep -Fq 'CLASH_VERGE_SYSTEM_DNS_DISABLED' "$(target_script)" 2>/dev/null
}

resign_outer_bundle() {
  # Do not use --deep: the separately signed privileged helper must remain untouched.
  sudo /usr/bin/codesign --force --sign - --identifier "$EXPECTED_BUNDLE_ID" "$app_path"
  /usr/bin/codesign --verify --deep --strict --verbose=2 "$app_path"
}

install_patch() {
  local target backup temp_file
  target="$(target_script)"
  backup="$(backup_script)"
  [ -f "$target" ] || fail "Expected DNS helper script is missing: $target"

  if is_patched; then
    echo "Already installed: Clash Verge system-DNS writes are disabled."
    return
  fi

  if [ ! -f "$backup" ]; then
    sudo /bin/cp -p "$target" "$backup"
    echo "Original script backed up at: $backup"
  fi

  temp_file="$(mktemp "${TMPDIR:-/tmp}/clash-verge-set-dns.XXXXXX")"
  trap '[ -z "${temp_file:-}" ] || rm -f "$temp_file"' EXIT
  /usr/bin/tee "$temp_file" >/dev/null <<'PATCH'
#!/bin/bash
# CLASH_VERGE_SYSTEM_DNS_DISABLED
# This wrapper deliberately reports success without changing macOS DNS settings.
# Clash Verge can still run TUN and Mihomo DNS internally.
exit 0
PATCH
  /bin/chmod 755 "$temp_file"
  sudo /usr/bin/install -m 755 "$temp_file" "$target"
  resign_outer_bundle
  echo "Installed. Restart Clash Verge, then check: networksetup -getdnsservers Wi-Fi"
}

restore_patch() {
  local target backup
  target="$(target_script)"
  backup="$(backup_script)"
  [ -f "$backup" ] || fail "No backup found: $backup"

  sudo /bin/cp -p "$backup" "$target"
  resign_outer_bundle
  echo "Restored the original Clash Verge DNS helper."
}

show_status() {
  local target backup
  target="$(target_script)"
  backup="$(backup_script)"
  [ -f "$target" ] || fail "Expected DNS helper script is missing: $target"

  if is_patched; then
    echo "Status: patched; Clash Verge cannot write system DNS through set_dns.sh."
  else
    echo "Status: unpatched."
  fi
  [ -f "$backup" ] && echo "Backup: $backup" || echo "Backup: not present"
}

require_macos
resolve_app

case "$action" in
  install) install_patch ;;
  restore) restore_patch ;;
  status) show_status ;;
  *) usage ;;
esac
