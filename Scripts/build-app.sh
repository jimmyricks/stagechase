#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/.build/StageChase.app"

cd "$ROOT"
swift build -c release --product StageChase
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/.build/release/StageChase" "$APP/Contents/MacOS/StageChase"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/StageChaseIcon.icns" "$APP/Contents/Resources/StageChaseIcon.icns"
printf 'Built %s\n' "$APP"
