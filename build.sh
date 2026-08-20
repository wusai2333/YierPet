#!/bin/bash
# 一键构建 YierPet.app（只需 Xcode Command Line Tools，无需完整 Xcode）
set -e
cd "$(dirname "$0")"

APP=build/YierPet.app
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# 部署目标 macOS 15.0：不指定 -target 时 swiftc 会用宿主系统版本（如 26），
# 产物就无法在旧系统上运行。架构跟随构建机（arm64 / x86_64）。
MIN_MACOS=15.0

echo "正在编译..."
swiftc -O -target "$(uname -m)-apple-macos${MIN_MACOS}" \
  Sources/YierPet/*.swift -o "$APP/Contents/MacOS/YierPet"

cp Info.plist "$APP/Contents/Info.plist"
cp Sources/YierPet/Resources/spritesheet.webp "$APP/Contents/Resources/"

# 表情包资源（一二/布布/合体三套帧序列）
if [ -d Assets/Packs ]; then
  rm -rf "$APP/Contents/Resources/Packs"
  cp -R Assets/Packs "$APP/Contents/Resources/Packs"
fi

echo "构建完成：$APP"
echo "启动：open $APP"
