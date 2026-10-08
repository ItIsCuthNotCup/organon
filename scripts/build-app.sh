#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

swift build -c release -Xswiftc -warnings-as-errors
APP="$ROOT/build/Notch.app"
CONTENTS="$APP/Contents"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp "$ROOT/.build/release/Notch" "$CONTENTS/MacOS/Notch"
cp "$ROOT/Resources/Info.plist" "$CONTENTS/Info.plist"
if [[ -d "$ROOT/Resources/AppIcon" ]]; then
    cp -R "$ROOT/Resources/AppIcon" "$CONTENTS/Resources/"
fi
codesign --force --deep -s - "$APP"

if [[ "${1:-}" == "--install" ]]; then
    if [[ -e /Applications/Notch.app ]]; then
        rm -rf /Applications/Notch.app
    fi
    cp -R "$APP" /Applications/Notch.app
fi

printf 'Built %s\n' "$APP"
