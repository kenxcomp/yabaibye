#!/usr/bin/env bash
set -euo pipefail
MODE="${1:-run}"
case "$MODE" in run|--build-only|--verify|--debug|--logs|--telemetry|--diagnose) ;; *) echo "usage: $0 [--build-only|--verify|--debug|--logs|--telemetry|--diagnose]" >&2; exit 2;; esac
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
APP_BUNDLE="$ROOT_DIR/dist/Yabaibye.app"
if [[ "$MODE" == --diagnose && -x "$APP_BUNDLE/Contents/MacOS/Yabaibye" ]]; then
  exec "$APP_BUNDLE/Contents/MacOS/Yabaibye" --diagnose
fi
if [[ "$MODE" != --diagnose ]]; then
  # Ask the app to quit gracefully so temporary accessibility settings are restored.
  if pgrep -x Yabaibye >/dev/null; then
    osascript -e 'tell application id "com.kenxcomp.yabaibye" to quit' || true
    for attempt in {1..30}; do pgrep -x Yabaibye >/dev/null || break; sleep 0.1; done
    if pgrep -x Yabaibye >/dev/null; then echo "Yabaibye is still shutting down. Retry shortly." >&2; exit 1; fi
  fi
fi
swift build
BIN_DIR="$(swift build --show-bin-path)"
SIGN_IDENTITY="${YABAIBYE_SIGN_IDENTITY:-}"
if [[ -z "$SIGN_IDENTITY" && -f .signing-identity ]]; then SIGN_IDENTITY="$(cat .signing-identity)"; fi
python3 script/bundle_app.py --binary "$BIN_DIR/Yabaibye" --output "$APP_BUNDLE" --identity "${SIGN_IDENTITY:--}"
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
