#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SDK="${FFGL_SDK_PATH:-$ROOT/.build/ffgl-sdk}"
CHECK="$ROOT/.build/ffgl-render-smoke"
SMOKE_HOME="$ROOT/.build/ffgl-smoke-home"

bash "$ROOT/Scripts/build-ffgl.sh"
clang++ \
    -std=c++17 \
    -mmacosx-version-min=10.15 \
    -arch arm64 \
    -I "$SDK/source/lib/ffgl" \
    "$ROOT/Scripts/ffgl-render-smoke.cpp" \
    -framework OpenGL \
    -o "$CHECK"
mkdir -p "$SMOKE_HOME"
HOME="$SMOKE_HOME" "$CHECK" "$ROOT/.build/StageChaseFFGL.bundle/Contents/MacOS/StageChaseFFGL" chase
HOME="$SMOKE_HOME" "$CHECK" "$ROOT/.build/StageChaseOutline.bundle/Contents/MacOS/StageChaseOutline" outline
HOME="$SMOKE_HOME" "$CHECK" "$ROOT/.build/StageChaseBumper.bundle/Contents/MacOS/StageChaseBumper" bumper
HOME="$SMOKE_HOME" "$CHECK" "$ROOT/.build/StageChaseWiper.bundle/Contents/MacOS/StageChaseWiper" wiper
