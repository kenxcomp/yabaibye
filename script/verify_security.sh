#!/usr/bin/env bash
set -euo pipefail
APP_BUNDLE="${1:?usage: verify_security.sh path/to/Yabaibye.app}"
codesign --verify --strict "$APP_BUNDLE"
python3 - "$APP_BUNDLE" <<'PY'
import plistlib, re, subprocess, sys
bundle = sys.argv[1]
info = subprocess.run(['codesign', '-dvvv', bundle], capture_output=True, text=True, check=True).stderr
match = re.search(r'flags=0x([0-9a-fA-F]+)', info)
if not match or not int(match.group(1), 16) & 0x10000:
    raise SystemExit('Missing Hardened Runtime in app signature')
raw = subprocess.run(['codesign', '-d', '--entitlements', '-', '--xml', bundle], capture_output=True, check=True).stdout
entitlements = plistlib.loads(raw) if raw.strip() else {}
exceptions = [key for key, value in entitlements.items() if value and (key.startswith('com.apple.security.cs.') or key == 'com.apple.security.get-task-allow')]
if exceptions:
    raise SystemExit('Unexpected runtime exceptions: ' + ', '.join(exceptions))
print('Signature verified: Hardened Runtime enabled; no runtime exception entitlements')
PY
