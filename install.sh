#!/bin/bash
# 一行安装 PSD字体打包：
#   curl -fsSL https://raw.githubusercontent.com/tianfeng66/psd-font-pack/main/install.sh | bash
# 下载最新版，装到「应用程序」，然后打开。用 curl 下载的文件不带隔离标记，所以不会被系统拦截。
set -euo pipefail

REPO="tianfeng66/psd-font-pack"
URL="https://github.com/$REPO/releases/latest/download/PSDFontPack.zip"
APP="PSD字体打包.app"

if [ "$(uname)" != "Darwin" ]; then
    echo "这个工具只能在 Mac 上用。" >&2
    exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "==> 下载最新版…"
curl -fL --progress-bar -o "$TMP/app.zip" "$URL"
ditto -x -k "$TMP/app.zip" "$TMP/x"
SRC="$(find "$TMP/x" -maxdepth 3 -name "$APP" -type d | head -1)"
if [ -z "$SRC" ]; then
    echo "下载的压缩包里没有找到 $APP" >&2
    exit 1
fi

DEST="/Applications"
if [ ! -w "$DEST" ]; then
    DEST="$HOME/Applications"
    mkdir -p "$DEST"
fi

osascript -e 'tell application id "com.tian.psdfontpack" to quit' >/dev/null 2>&1 || true
rm -rf "$DEST/$APP"
ditto "$SRC" "$DEST/$APP"
xattr -cr "$DEST/$APP" 2>/dev/null || true

echo "==> 已安装到 $DEST/$APP"
open "$DEST/$APP"
