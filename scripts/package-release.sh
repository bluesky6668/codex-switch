#!/bin/bash
# 生成同时支持 Apple Silicon 与 Intel Mac 的 Release 压缩包。
set -euo pipefail
cd "$(dirname "$0")/.."

SOURCE_VERSION="$(sed -n 's/.*toolVersion = "\([^"]*\)".*/\1/p' Sources/Core/Version.swift)"
VERSION="${1:-v$SOURCE_VERSION}"
VERSION="${VERSION#v}"
if [ "$VERSION" != "$SOURCE_VERSION" ]; then
    echo "标签版本 v$VERSION 与源码版本 $SOURCE_VERSION 不一致" >&2
    exit 1
fi
WORK_DIR=".build/release"
PRODUCT_DIR="$WORK_DIR/Codex Switch $VERSION"
APP="$PRODUCT_DIR/Codex Switch.app"
DIST_DIR="dist"
ARCHS=(arm64 x86_64)
FLAGS=(-O -swift-version 5 -module-cache-path "$WORK_DIR/module-cache")

rm -rf "$WORK_DIR" "$DIST_DIR"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$DIST_DIR" "$WORK_DIR/module-cache"

for arch in "${ARCHS[@]}"; do
    mkdir -p "$WORK_DIR/$arch"
    swiftc "${FLAGS[@]}" -target "$arch-apple-macos14.0" \
        -o "$WORK_DIR/$arch/codex-switch" Sources/Core/*.swift Sources/CLI/*.swift
    swiftc "${FLAGS[@]}" -target "$arch-apple-macos14.0" -parse-as-library \
        -o "$WORK_DIR/$arch/CodexSwitch" Sources/Core/*.swift Sources/App/*.swift
done

lipo -create "$WORK_DIR/arm64/codex-switch" "$WORK_DIR/x86_64/codex-switch" \
    -output "$PRODUCT_DIR/codex-switch"
lipo -create "$WORK_DIR/arm64/CodexSwitch" "$WORK_DIR/x86_64/CodexSwitch" \
    -output "$APP/Contents/MacOS/CodexSwitch"

cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp README.md LICENSE SECURITY.md "$PRODUCT_DIR/"

codesign --force --sign - --identifier com.local.codex-switch "$PRODUCT_DIR/codex-switch"
codesign --force --sign - --identifier com.local.codex-switch.app "$APP"

ARCHIVE="$DIST_DIR/Codex-Switch-v$VERSION-macOS-universal.zip"
ditto -c -k --sequesterRsrc --keepParent "$PRODUCT_DIR" "$ARCHIVE"
(
    cd "$DIST_DIR"
    shasum -a 256 "$(basename "$ARCHIVE")" > SHA256SUMS.txt
)

echo "已生成 $ARCHIVE"
