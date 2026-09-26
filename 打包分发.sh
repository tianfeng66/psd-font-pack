#!/bin/bash
# 构建并打出可以直接发给同事的压缩包：dist/PSD字体打包-v<版本>.zip
# 用法：./打包分发.sh [版本号，默认读 Info.plist]
set -euo pipefail
cd "$(dirname "$0")"

VER="${1:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)}"
NAME="PSD字体打包"

./build.sh

STAGE="$(mktemp -d)/$NAME"
mkdir -p "$STAGE" dist
cp -R "build/$NAME.app" "$STAGE/"
cp "① 先看这里.txt" "$STAGE/"

OUT="dist/$NAME-v$VER.zip"
rm -f "$OUT"
# 用 ditto 打包：能完整保留 .app 的签名和权限。
# 它不设 UTF-8 文件名标记，但这个包只给 Mac 用，访达解压中文名是正常的。
ditto -c -k --norsrc --noextattr --keepParent "$STAGE" "$OUT"
rm -rf "$(dirname "$STAGE")"
# GitHub Release 的附件名不能有中文，install.sh 下载的是这个固定名字
cp "$OUT" dist/PSDFontPack.zip

echo
echo "分发包：${PWD}/${OUT}（$(du -h "$OUT" | cut -f1)）"
