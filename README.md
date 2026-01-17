# ZoomFixer (macOS)

Native SwiftUI helper that walks through the common fixes for Zoom error 1132: clearing caches, removing duplicates, resetting DNS, downloading the latest installer, and reinstalling Zoom with repaired permissions.

## Project layout
- `ZoomFixer/` – SwiftUI app sources and assets
- `ZoomFixer.xcodeproj` – Xcode project for the macOS app
- `Scripts/fix-zoom.sh` – standalone repair script
- `Scripts/uninstall-zoom.sh` – remove Zoom and user data
- `Scripts/create-dmg.sh` – package a built app into a DMG
- `Scripts/run-zoom-docker.sh` – launch Zoom inside a Docker sandbox
- `Docker/` – build context for the sandbox image (Ubuntu + Zoom + noVNC)
- `ZoomFixer.Windows/` – PowerShell repair script and WiX manifest for Windows MSI

## Building the app
1. Open `ZoomFixer.xcodeproj` in Xcode.
2. Select the `ZoomFixer` scheme and a macOS destination.
3. Build and run. The main window shows a Fix button, status indicator, and live log output for each step.

The app requests elevation when needed (DNS reset, installer, permissions) via an AppleScript prompt.

## Using the scripts
- Run the full repair from a terminal:
  ```bash
  bash Scripts/fix-zoom.sh
  ```
- Uninstall Zoom and clear user data:
  ```bash
  bash Scripts/uninstall-zoom.sh
  ```
- Package a built app into a DMG (defaults to `../build/Release/ZoomFixer.app`):
  ```bash
  bash Scripts/create-dmg.sh
  ```
- Launch Zoom in a sandboxed Linux container (fresh device identity):
  ```bash
  bash Scripts/run-zoom-docker.sh
  ```
  Connect via browser (noVNC) at http://localhost:6080/vnc.html or with a VNC client on localhost:5901.

## Notes
- Target macOS 12.0+.
- Download URL: `https://zoom.us/client/latest/Zoom.pkg`.
- Docker sandbox requires Docker Desktop running; the app’s “Launch Docker Sandbox” button builds/starts the same image on demand and logs progress.
- In-app Docker helpers: “One-click Sandbox” will try to install Docker via Homebrew (if present), start Docker Desktop, and then launch the sandbox. “Re-check Docker” validates CLI/daemon availability; “Install via Homebrew” runs `brew install --cask docker` (requires Homebrew); “Install Docker” opens the Docker Desktop download page.
- The app continues after individual step failures and surfaces warnings at the end of the run.

## Windows MSI (repair tool)
- PowerShell script: `ZoomFixer.Windows/FixZoom1132.ps1` (self-elevating, clears Zoom data, flushes DNS, downloads + installs latest MSI).
- WiX manifest: `ZoomFixer.Windows/ZoomFixer.wxs` packages the script and a Start Menu shortcut that runs it with PowerShell.
- Build MSI (on Windows with WiX installed):
  ```powershell
  cd ZoomFixer.Windows
  powershell -ExecutionPolicy Bypass -File .\build-wix.ps1
  ```
  Outputs `ZoomFixer.Windows/ZoomFixer.msi`.
