#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
if [[ "$(uname -m)" != arm64 ]]; then
  print -u2 'Build on Apple Silicon macOS.'
  exit 1
fi
command -v swift codesign >/dev/null
swift build -c release --arch arm64
BIN_DIR=$(swift build -c release --arch arm64 --show-bin-path)
APP="$PWD/dist/Codex Limits.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/CodexLimits" "$APP/Contents/MacOS/CodexLimits"
cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
codesign --verify --strict "$APP"
print "Built: $APP"
