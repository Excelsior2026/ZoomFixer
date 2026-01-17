#!/usr/bin/env bash
# ZoomFixer - repair script for Zoom error 1132

set -uo pipefail

ZOOM_URL="https://zoom.us/client/latest/Zoom.pkg"
WORKDIR="$(mktemp -d /tmp/zoomfixer.XXXXXX)"

log() { printf "[%s] %s\n" "$(date +"%H:%M:%S")" "$*"; }

cleanup() {
  rm -rf "$WORKDIR"
}
trap cleanup EXIT

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

  kill_zoom
  clear_cache
  clear_preferences
  remove_logs
  remove_installations
  reset_dns
  download_zoom
  install_zoom
  fix_permissions

  if verify_install; then
    log "Zoom reinstall completed"
  else
    log "Zoom install not detected after reinstall"
    exit 1
  fi
}

main "$@"
