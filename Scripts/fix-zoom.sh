#!/usr/bin/env bash
# ZoomFixer - repair script for Zoom error 1132
# Includes system-level change detection & repair phase.

set -uo pipefail

ZOOM_URL="https://zoom.us/client/latest/Zoom.pkg"
WORKDIR="$(mktemp -d /tmp/zoomfixer.XXXXXX)"
FW="/usr/libexec/ApplicationFirewall/socketfilterfw"

log() { printf "[%s] %s\n" "$(date +"%H:%M:%S")" "$*"; }

cleanup() {
  rm -rf "$WORKDIR"
}
trap cleanup EXIT

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 1 – Detect and repair system-level changes that cause error 1132
# ─────────────────────────────────────────────────────────────────────────────

check_hosts_file() {
  log "[hosts] Checking /etc/hosts for Zoom-blocking entries"
  local ZOOM_DOMAINS=(
    zoom.us us04web.zoom.us us02web.zoom.us us06web.zoom.us
    us02ws.zoom.us us04ws.zoom.us controlplane.zoom.us
    us04mon.zoom.us us04stun1.zoom.us logcs.zoom.us
  )

  local FOUND=0
  for domain in "${ZOOM_DOMAINS[@]}"; do
    # Match lines that map the domain to 0.0.0.0 or 127.x
    if grep -Eq "^(0\.0\.0\.0|127\.[0-9]+\.[0-9]+\.[0-9]+)[[:space:]]+.*${domain}" /etc/hosts 2>/dev/null; then
      log "[hosts] BLOCKING entry found for ${domain} — removing"
      sudo sed -i '' "/^\(0\.0\.0\.0\|127\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\)[[:space:]].*${domain}/d" /etc/hosts
      FOUND=1
    fi
  done

  if [ "$FOUND" -eq 0 ]; then
    log "[hosts] No Zoom-blocking entries found"
  else
    log "[hosts] Blocking entries removed from /etc/hosts"
  fi
}

check_firewall() {
  log "[firewall] Checking macOS Application Firewall for Zoom blocks"
  [ -x "$FW" ] || { log "[firewall] socketfilterfw not found — skipping"; return; }

  for app in "/Applications/zoom.us.app" "/Applications/Zoom.app" "/Applications/Zoom Workplace.app"; do
    if [ -d "$app" ]; then
      sudo "$FW" --remove "$app"     2>/dev/null || true
      sudo "$FW" --add "$app"        2>/dev/null || true
      sudo "$FW" --unblockapp "$app" 2>/dev/null || true
      log "[firewall] Ensured $app is allowed in Application Firewall"
    fi
  done
}

check_network_interfaces() {
  log "[network] Checking for APIPA/link-local addresses (DHCP failure)"
  local APIPA_IFACES
  APIPA_IFACES=$(ifconfig -a | awk '
    /^[^ \t]/ { iface = $1; gsub(/:$/, "", iface) }
    /inet 169\.254\./ { print iface }
  ')

  if [ -z "$APIPA_IFACES" ]; then
    log "[network] No APIPA addresses detected — interfaces look healthy"
    return
  fi

  echo "$APIPA_IFACES" | while read -r iface; do
    log "[network] APIPA address on $iface — attempting DHCP renewal"
    sudo ipconfig set "$iface" DHCP 2>/dev/null \
      && log "[network] DHCP renewal issued for $iface" \
      || log "[network][warn] DHCP renewal failed for $iface"
  done
}

check_tls_trust() {
  log "[tls] Checking TLS trust for zoom.us"
  if ! command -v openssl &>/dev/null; then
    log "[tls] openssl not found — skipping TLS check"
    return
  fi

  local TLS_OUT
  TLS_OUT=$(openssl s_client -connect zoom.us:443 -brief </dev/null 2>&1 | head -5)

  if echo "$TLS_OUT" | grep -q "Verification: OK\|verify return:1"; then
    log "[tls] zoom.us TLS certificate verifies OK"
  else
    log "[tls][warn] TLS verification issue for zoom.us:"
    echo "$TLS_OUT" | while IFS= read -r line; do log "  $line"; done
    log "[tls][warn] Check Keychain Access > System Roots for untrusted/modified certs."
  fi
}

audit_network_extensions() {
  log "[netext] Auditing VPN / network kernel extensions"
  local KEXT_OUT
  KEXT_OUT=$(kextstat 2>/dev/null | grep -iE 'vpn|tunnel|filter|proxy|checkpoint|sophos|symantec|mcafee|crowdstrike|carbon' || echo '')

  if [ -z "$KEXT_OUT" ]; then
    log "[netext] No known VPN/security kernel extensions detected"
  else
    log "[netext][warn] Potentially interfering network extensions:"
    echo "$KEXT_OUT" | while IFS= read -r line; do log "  $line"; done
    log "[netext][warn] If error 1132 persists, try disabling VPN/security software."
  fi
}

check_sip() {
  log "[sip] Checking System Integrity Protection status"
  local SIP_STATUS
  SIP_STATUS=$(csrutil status 2>/dev/null || echo 'unknown')

  if echo "$SIP_STATUS" | grep -q "enabled"; then
    log "[sip] SIP is ENABLED ✓"
  elif echo "$SIP_STATUS" | grep -q "disabled"; then
    log "[sip][warn] SIP is DISABLED. This allows deep system modifications that can break Zoom."
    log "[sip][warn] To re-enable: boot into Recovery Mode > Utilities > Terminal > csrutil enable"
  else
    log "[sip] SIP status: $SIP_STATUS"
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 2 – Standard Zoom repair
# ─────────────────────────────────────────────────────────────────────────────

kill_zoom() {
  log "Killing running Zoom processes"
  pkill -9 -f "zoom.us" 2>/dev/null || true
  pkill -9 -x "zoom.us" 2>/dev/null || true
}

clear_cache() {
  log "Clearing Zoom cache"
  rm -rf "$HOME/Library/Application Support/zoom.us"
}

clear_preferences() {
  log "Clearing Zoom preferences"
  rm -f "$HOME/Library/Preferences/us.zoom."*
}

remove_logs() {
  log "Removing Zoom logs"
  rm -rf "$HOME/Library/Logs/zoom.us"
}

find_duplicates() {
  log "Searching for duplicate Zoom installations"
  find /Applications "$HOME/Applications" "$HOME/Library/Application Support" \
    -maxdepth 4 -iname "zoom*.app" 2>/dev/null
}

remove_installations() {
  log "Removing Zoom installations"
  while IFS= read -r app; do
    [ -z "$app" ] && continue
    if [[ "$app" == /Applications/* ]]; then
      sudo rm -rf "$app"
    else
      rm -rf "$app"
    fi
    log "Removed $app"
  done < <(find_duplicates)
}

reset_dns() {
  log "Resetting DNS cache"
  sudo dscacheutil -flushcache
  sudo killall -HUP mDNSResponder || true
}

download_zoom() {
  log "Downloading latest Zoom package"
  curl -L "$ZOOM_URL" -o "$WORKDIR/Zoom.pkg"
}

install_zoom() {
  log "Installing Zoom"
  sudo installer -pkg "$WORKDIR/Zoom.pkg" -target /
}

fix_permissions() {
  for app in "/Applications/zoom.us.app" "/Applications/Zoom.app" "/Applications/Zoom Workplace.app"; do
    if [ -d "$app" ]; then
      log "Fixing permissions for $app"
      sudo chown -R root:wheel "$app"
      sudo chmod -R 755 "$app"
    fi
  done
}

allow_in_firewall_post_install() {
  log "Re-allowing Zoom in Application Firewall after install"
  [ -x "$FW" ] || return
  for app in "/Applications/zoom.us.app" "/Applications/Zoom.app" "/Applications/Zoom Workplace.app"; do
    if [ -d "$app" ]; then
      sudo "$FW" --add "$app"        2>/dev/null || true
      sudo "$FW" --unblockapp "$app" 2>/dev/null || true
    fi
  done
}

verify_install() {
  for app in "/Applications/zoom.us.app" "/Applications/Zoom.app" "/Applications/Zoom Workplace.app"; do
    if [ -d "$app" ]; then
      log "Installation verified at $app"
      return 0
    fi
  done
  return 1
}

main() {
  log "ZoomFixer starting"

  log "── Phase 1: System-change detection & repair ──"
  check_hosts_file
  check_firewall
  check_network_interfaces
  check_tls_trust
  audit_network_extensions
  check_sip

  log "── Phase 2: Standard Zoom repair ──"
  kill_zoom
  clear_cache
  clear_preferences
  remove_logs
  remove_installations
  reset_dns
  download_zoom
  install_zoom
  fix_permissions
  allow_in_firewall_post_install

  if verify_install; then
    log "Zoom reinstall completed"
  else
    log "Zoom install not detected after reinstall"
    exit 1
  fi
}

main "$@"
