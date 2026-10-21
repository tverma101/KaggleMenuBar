#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
PRODUCT_NAME="KaggleMenuBar"
APP_NAME="KaggleMenuBar"
APP_BUNDLE_NAME="KaggleMenuBar.app"
# Kept from the app's first name so the launch agent, Hidden Bar position and
# kaggle-hub's refresh notification keep working across the rename.
BUNDLE_ID="app.kernelwatch.KernelWatch"
LEGACY_APP_NAME="Kaggle"
MIN_SYSTEM_VERSION="14.0"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_BUNDLE_NAME"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
INSTALL_BUNDLE="/Applications/$APP_BUNDLE_NAME"
AGENT_LABEL="$BUNDLE_ID"
AGENT_PLIST="$HOME/Library/LaunchAgents/$AGENT_LABEL.plist"
AGENT_DOMAIN="gui/$(id -u)"
LEGACY_INSTALL_BUNDLE="/Applications/$LEGACY_APP_NAME.app"
LEGACY_USER_LINK="$HOME/Applications/$LEGACY_APP_NAME.app"

# Build before stopping anything: a failed build must leave monitoring running.
swift build
BUILD_BINARY="$(swift build --show-bin-path)/$PRODUCT_NAME"

mkdir -p "$APP_MACOS" "$APP_RESOURCES"
cp -f "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"
cp -f "$ROOT_DIR/Resources/AppIcon.icns" "$APP_RESOURCES/AppIcon.icns"

cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundleDisplayName</key>
  <string>$APP_NAME</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.2.0</string>
  <key>CFBundleVersion</key>
  <string>2</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

# Seal the whole app, including its resources, with a stable bundle identifier.
/usr/bin/codesign --force --sign - --identifier "$BUNDLE_ID" "$APP_BUNDLE"
/usr/bin/codesign --verify --deep --strict "$APP_BUNDLE"

# Unloading the agent first stops launchd from restarting the installed app
# while it is replaced, or beside a development copy.
stop_app() {
  /bin/launchctl bootout "$AGENT_DOMAIN/$AGENT_LABEL" >/dev/null 2>&1 || true
  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
  pkill -x "$LEGACY_APP_NAME" >/dev/null 2>&1 || true
}

open_app() {
  stop_app
  /usr/bin/open -n "$APP_BUNDLE"
  echo "Running the development build. Run '$0 --install' to restore normal monitoring."
}

# Starts at login and comes back after a crash or kill. Quit from the panel
# exits cleanly and stays quit until the next login.
write_agent() {
  mkdir -p "$(dirname "$AGENT_PLIST")"
  cat >"$AGENT_PLIST" <<AGENT
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$AGENT_LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$INSTALL_BUNDLE/Contents/MacOS/$APP_NAME</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <dict>
    <key>SuccessfulExit</key>
    <false/>
  </dict>
  <key>ProcessType</key>
  <string>Interactive</string>
  <key>ThrottleInterval</key>
  <integer>10</integer>
  <key>LimitLoadToSessionType</key>
  <string>Aqua</string>
</dict>
</plist>
AGENT
  /usr/bin/plutil -lint "$AGENT_PLIST" >/dev/null
}

# macOS 27's menu bar assessment allow-list needs the app in /Applications.
install_app() {
  stop_app
  if [[ -e "$INSTALL_BUNDLE" ]]; then
    /usr/bin/trash "$INSTALL_BUNDLE"
  fi
  # Copies installed under the app's first name.
  if [[ -e "$LEGACY_INSTALL_BUNDLE" ]]; then
    /usr/bin/trash "$LEGACY_INSTALL_BUNDLE"
  fi
  if [[ -L "$LEGACY_USER_LINK" ]]; then
    /usr/bin/trash "$LEGACY_USER_LINK"
  fi
  /usr/bin/ditto "$APP_BUNDLE" "$INSTALL_BUNDLE"
  /usr/bin/touch "$INSTALL_BUNDLE"
  write_agent
  /bin/launchctl bootstrap "$AGENT_DOMAIN" "$AGENT_PLIST"
  echo "Installed $INSTALL_BUNDLE; launch agent $AGENT_LABEL keeps it running."
}

case "$MODE" in
  run)
    open_app
    ;;
  --install|install)
    install_app
    ;;
  --build-only|build-only)
    echo "Built $APP_BUNDLE"
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  *)
    echo "usage: $0 [run|--install|--build-only|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
