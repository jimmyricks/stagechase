#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SDK="${FFGL_SDK_PATH:-$ROOT/.build/ffgl-sdk}"
OUTPUT="$ROOT/.build"

if [[ ! -d "$SDK/source/lib/ffgl" ]]; then
    printf 'Resolume FFGL SDK not found at %s\n' "$SDK" >&2
    printf 'Set FFGL_SDK_PATH to the local SDK checkout.\n' >&2
    exit 1
fi

build_plugin() {
    local bundle="$1"
    local plist="$2"
    local source="$3"
    local kind="$4"
    local destination="$OUTPUT/$bundle.bundle"
    mkdir -p "$destination/Contents/MacOS"
    clang++ \
        -std=c++17 \
        -mmacosx-version-min=10.15 \
        -arch arm64 \
        -arch x86_64 \
        -fPIC \
        -bundle \
        -D TARGET_OS_MAC=1 \
        -D GL_SILENCE_DEPRECATION \
        -D STAGECHASE_EFFECT_KIND="$kind" \
        -Wno-deprecated-declarations \
        -I "$SDK/source/lib" \
        -I "$SDK/source/lib/ffglquickstart" \
        -I "$SDK/source/lib/ffglex" \
        -I "$SDK/source/lib/glsdk_0_5_2" \
        -I "$SDK/source/plugins/AddSubtract" \
        "$SDK"/source/lib/ffgl/*.cpp \
        "$SDK"/source/lib/ffglex/*.cpp \
        "$SDK"/source/lib/ffglquickstart/*.cpp \
        "$source" \
        -framework OpenGL \
        -framework Carbon \
        -framework AppKit \
        -o "$destination/Contents/MacOS/$bundle"
    cp "$ROOT/Plugins/StageChaseFFGL/$plist" "$destination/Contents/Info.plist"
    printf 'Built %s\n' "$destination"
}

build_plugin StageChaseFFGL Info.plist "$ROOT/Plugins/StageChaseFFGL/StageChaseFFGL.cpp" 0
build_plugin StageChaseOutline Outline-Info.plist "$ROOT/Plugins/StageChaseFFGL/MovementEffects.cpp" 1
build_plugin StageChaseBumper Bumper-Info.plist "$ROOT/Plugins/StageChaseFFGL/MovementEffects.cpp" 2
build_plugin StageChaseWiper Wiper-Info.plist "$ROOT/Plugins/StageChaseFFGL/MovementEffects.cpp" 3
