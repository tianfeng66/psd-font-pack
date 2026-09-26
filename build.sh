#!/bin/bash
# 构建「PSD字体打包.app」—— 只需要 Xcode Command Line Tools
set -euo pipefail

cd "$(dirname "$0")"
ROOT="$PWD"
BUILD="$ROOT/build"
APP="$BUILD/PSD字体打包.app"
SDK="$(xcrun --show-sdk-path --sdk macosx)"

# 通用二进制，Intel 和 Apple 芯片的 Mac 都能用
ARCHS=("arm64" "x86_64")
DEPLOY="13.0"

echo "==> 清理"
rm -rf "$BUILD"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> 生成图标"
mkdir -p "$BUILD/icontool"
xcrun swiftc -O -sdk "$SDK" -target "$(uname -m)-apple-macos$DEPLOY" \
    -o "$BUILD/icontool/makeicon" Tools/makeicon.swift
"$BUILD/icontool/makeicon" "$APP/Contents/Resources/AppIcon.icns" "$BUILD/icon.png" >/dev/null

echo "==> 编译"
SOURCES=(Sources/*.swift)
SLICES=()
for arch in "${ARCHS[@]}"; do
    out="$BUILD/PSDFontPack-$arch"
    if xcrun swiftc -O -swift-version 5 \
        -sdk "$SDK" -target "$arch-apple-macos$DEPLOY" \
        -framework AppKit -framework SwiftUI -framework CoreText -lz \
        -o "$out" "${SOURCES[@]}" 2>"$BUILD/$arch.log"; then
        SLICES+=("$out")
        echo "    $arch ✓"
    else
        echo "    $arch ✗（见 $BUILD/$arch.log）"
    fi
done

if [ ${#SLICES[@]} -ne ${#ARCHS[@]} ]; then
    echo "编译失败，日志："
    cat "$BUILD"/*.log
    exit 1
fi

lipo -create -output "$APP/Contents/MacOS/PSDFontPack" "${SLICES[@]}"
chmod +x "$APP/Contents/MacOS/PSDFontPack"

echo "==> 打包"
cp Resources/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> 签名（ad-hoc）"
codesign --force --deep --sign - --options runtime "$APP" 2>/dev/null \
    || codesign --force --deep --sign - "$APP"
xattr -cr "$APP" || true

echo
echo "完成：$APP"
