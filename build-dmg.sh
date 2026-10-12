#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
command -v hdiutil ditto >/dev/null
./build.sh
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)
STAGE=$(mktemp -d "${TMPDIR%/}/CodexLimits-DMG.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT
ditto "dist/Codex Limits.app" "$STAGE/Codex Limits.app"
ln -s /Applications "$STAGE/Applications"
DMG="$PWD/dist/Codex-Limits-${VERSION}-arm64.dmg"
hdiutil create -volname "Codex Limits" -srcfolder "$STAGE" -format UDZO -ov "$DMG"
hdiutil verify "$DMG"
print "Built: $DMG"
