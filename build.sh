#!/bin/bash
# 编译命令行工具 codex-switch 和菜单栏应用 Codex Switch.app，并做 ad-hoc 签名
# （钥匙串按代码签名识别程序）。
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p .build
FLAGS=(-O -swift-version 5 -target "$(uname -m)-apple-macos14.0")

swiftc "${FLAGS[@]}" -o .build/codex-switch Sources/Core/*.swift Sources/CLI/*.swift
codesign --force --sign - --identifier com.local.codex-switch .build/codex-switch

[ "${1:-}" = "--cli-only" ] && { echo "已生成 .build/codex-switch"; exit 0; }

APP=".build/Codex Switch.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc "${FLAGS[@]}" -parse-as-library -o "$APP/Contents/MacOS/CodexSwitch" Sources/Core/*.swift Sources/App/*.swift
cp Resources/Info.plist "$APP/Contents/Info.plist"

cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - --identifier com.local.codex-switch.app "$APP"

echo "已生成 .build/codex-switch 与 $APP"
