#!/usr/bin/env bash

set -euo pipefail

log() { printf "[%s] %s\n" "$(date +"%H:%M:%S")" "$*"; }

kill_zoom() {
  log "Stopping Zoom processes"
  pkill -9 -f "zoom.us" 2>/dev/null || true
  pkill -9 -x "zoom.us" 2>/dev/null || true
}

remove_apps() {
  for app in "/Applications/zoom.us.app" "/Applications/Zoom.app" "/Applications/Zoom Workplace.app" "$HOME/Applications/zoom.us.app" "$HOME/Applications/Zoom.app"; do
    if [ -d "$app" ]; then
      if [[ "$app" == /Applications/* ]]; then
        sudo rm -rf "$app"
      else
        rm -rf "$app"
      fi
      log "Removed $app"
    fi
  done
}

remove_data() {
  rm -rf "$HOME/Library/Application Support/zoom.us"
  rm -f "$HOME/Library/Preferences/us.zoom."*
  rm -rf "$HOME/Library/Logs/zoom.us"
  log "User data cleared"
}

main() {
  kill_zoom
  remove_apps
  remove_data
  log "Zoom uninstall complete"
}

main "$@"
