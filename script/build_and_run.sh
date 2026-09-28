#!/usr/bin/env bash
set -euo pipefail
MODE="${1:-run}"
case "$MODE" in run|--build-only|--verify|--debug|--logs|--telemetry|--diagnose) ;; *) echo "usage: $0 [--build-only|--verify|--debug|--logs|--telemetry|--diagnose]" >&2; exit 2;; esac
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
APP_BUNDLE="$ROOT_DIR/dist/Yabaibye.app"
if [[ "$MODE" != --build-only && "$MODE" != --diagnose ]]; then
  # Ask the app to quit gracefully so a pending synthetic drag is released.
  if pgrep -x Yabaibye >/dev/null; then
    osascript -e 'tell application id "com.kenxcomp.yabaibye" to quit' || true
    for attempt in {1..30}; do pgrep -x Yabaibye >/dev/null || break; sleep 0.1; done
    if pgrep -x Yabaibye >/dev/null; then echo "Yabaibye is still shutting down. Retry shortly." >&2; exit 1; fi
  fi
fi
swift build
BIN_DIR="$(swift build --show-bin-path)"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
cp "$BIN_DIR/Yabaibye" "$APP_BUNDLE/Contents/MacOS/Yabaibye"
cat > "$APP_BUNDLE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Yabaibye</string>
<key>CFBundleIdentifier</key><string>com.kenxcomp.yabaibye</string>
<key>CFBundleName</key><string>Yabaibye</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign "${YABAIBYE_SIGN_IDENTITY:--}" "$APP_BUNDLE"
case "$MODE" in
  --build-only) echo "$APP_BUNDLE" ;;
  --diagnose) "$APP_BUNDLE/Contents/MacOS/Yabaibye" --diagnose ;;
  --debug) lldb -- "$APP_BUNDLE/Contents/MacOS/Yabaibye" ;;
  *)
    /usr/bin/open "$APP_BUNDLE"
    case "$MODE" in
      --verify) sleep 1; pgrep -x Yabaibye ;;
      --logs) /usr/bin/log stream --info --style compact --predicate 'process == "Yabaibye"' ;;
      --telemetry) /usr/bin/log stream --info --style compact --predicate 'subsystem == "com.kenxcomp.yabaibye"' ;;
    esac ;;
esac
