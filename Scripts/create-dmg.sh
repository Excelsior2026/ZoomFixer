#!/usr/bin/env bash

set -euo pipefail

APP_PATH="${1:-../build/Release/ZoomFixer.app}"
DMG_NAME="${2:-ZoomFixer.dmg}"
DEST_DIR="${3:-../dist}"

log() { printf "[%s] %s\n" "$(date +"%H:%M:%S")" "$*"; }

if [ ! -d "$APP_PATH" ]; then
  log "App not found at $APP_PATH"
  exit 1
fi

mkdir -p "$DEST_DIR"

log "Creating DMG $DMG_NAME from $APP_PATH"
hdiutil create -volname "ZoomFixer" -srcfolder "$APP_PATH" -ov -format UDZO "$DEST_DIR/$DMG_NAME"

log "DMG created at $DEST_DIR/$DMG_NAME"
