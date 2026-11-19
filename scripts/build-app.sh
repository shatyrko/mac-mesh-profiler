#!/bin/bash
# Builds "Mac Mesh Profiler.app" into ./build. Works with just the Command Line
# Tools; a universal (arm64 + x86_64) build needs full Xcode.
#
#   scripts/build-app.sh             # release build for this Mac's architecture
#   scripts/build-app.sh --install   # also copy the app to /Applications
#   scripts/build-app.sh --zip       # also create build/MacMeshProfiler-<version>-macOS.zip
#
# Environment:
#   UNIVERSAL=1      build for arm64 and x86_64
#   VERSION=1.2.3    CFBundleShortVersionString (default: from Resources/Info.plist)
#   BUILD_NUMBER=42  CFBundleVersion (default: from Resources/Info.plist)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_NAME="Mac Mesh Profiler"
EXEC_NAME="MacMeshProfiler"
BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/$APP_NAME.app"

INSTALL=0
ZIP=0
for arg in "$@"; do
    case "$arg" in
        --install) INSTALL=1 ;;
        --zip) ZIP=1 ;;
        *) echo "unknown option: $arg" >&2; exit 2 ;;
    esac
done

ARCH_ARGS=()
if [ "${UNIVERSAL:-0}" = "1" ]; then
    ARCH_ARGS=(--arch arm64 --arch x86_64)
fi

echo "==> swift build (release${UNIVERSAL:+, universal})"
swift build -c release --product "$EXEC_NAME" ${ARCH_ARGS[@]+"${ARCH_ARGS[@]}"}
BIN="$(swift build -c release --product "$EXEC_NAME" ${ARCH_ARGS[@]+"${ARCH_ARGS[@]}"} --show-bin-path)/$EXEC_NAME"

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$EXEC_NAME"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

PLIST="$APP/Contents/Info.plist"
if [ -n "${VERSION:-}" ]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION#v}" "$PLIST"
fi
if [ -n "${BUILD_NUMBER:-}" ]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$PLIST"
fi
APP_VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST")"

ICNS="$BUILD_DIR/AppIcon.icns"
if [ ! -f "$ICNS" ] || [ "$ROOT/scripts/make-icon.swift" -nt "$ICNS" ]; then
    echo "==> rendering app icon"
    ICONSET="$BUILD_DIR/AppIcon.iconset"
    rm -rf "$ICONSET"
    mkdir -p "$ICONSET"
    swift "$ROOT/scripts/make-icon.swift" "$ICONSET"
    iconutil -c icns "$ICONSET" -o "$ICNS"
fi
cp "$ICNS" "$APP/Contents/Resources/AppIcon.icns"

echo "==> ad-hoc signing"
codesign --force --sign - --timestamp=none "$APP"

echo "==> built: $APP (version $APP_VERSION, $(lipo -archs "$APP/Contents/MacOS/$EXEC_NAME"))"

if [ "$ZIP" = "1" ]; then
    ZIP_PATH="$BUILD_DIR/$EXEC_NAME-$APP_VERSION-macOS.zip"
    rm -f "$ZIP_PATH" "$ZIP_PATH.sha256"
    ditto -c -k --norsrc --noextattr --keepParent "$APP" "$ZIP_PATH"
    (cd "$BUILD_DIR" && shasum -a 256 "$(basename "$ZIP_PATH")" > "$(basename "$ZIP_PATH").sha256")
    echo "==> zipped: $ZIP_PATH"
    cat "$ZIP_PATH.sha256"
fi

if [ "$INSTALL" = "1" ]; then
    echo "==> installing to /Applications"
    rm -rf "/Applications/$APP_NAME.app"
    cp -R "$APP" "/Applications/$APP_NAME.app"
    echo "==> installed: /Applications/$APP_NAME.app"
fi
