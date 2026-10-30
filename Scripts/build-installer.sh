#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Resources/Info.plist")"
DIST="$ROOT/dist"
STAGE="$DIST/payload"
PKG="$DIST/StageChase-$VERSION.pkg"
PLUGIN_DIR='Library/Graphics/FreeFrame Plug-Ins'

"$ROOT/Scripts/build-app.sh"

rm -rf "$DIST"
mkdir -p "$STAGE/Applications" "$STAGE/$PLUGIN_DIR"
cp -R "$ROOT/.build/StageChase.app" "$STAGE/Applications/StageChase.app"

if "$ROOT/Scripts/build-ffgl.sh" >/dev/null 2>&1; then
    shopt -s nullglob
    for bundle in "$ROOT"/.build/*.bundle; do
        cp -R "$bundle" "$STAGE/$PLUGIN_DIR/"
    done
    shopt -u nullglob
else
    printf 'FFGL SDK not found — skipping plugins, the .app still installs.\n' >&2
fi

pkgbuild \
    --root "$STAGE" \
    --identifier local.stagechase.installer \
    --version "$VERSION" \
    --install-location / \
    "$PKG"

printf 'Built %s\n' "$PKG"
printf 'Unsigned package — recipients may need to Control-click > Open to run it.\n'
