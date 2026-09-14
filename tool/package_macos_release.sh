#!/usr/bin/env bash
# 本地 macOS release 打包：只打编辑器本体，不预置语言包（Zed 式按需下载）。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "==> flutter build macos --release"
flutter build macos --release

APP="$(find build/macos/Build/Products/Release -maxdepth 1 -name '*.app' | head -1)"
test -n "$APP"
echo "==> app: $APP"

# 明确清理旧预置，避免残留 language_archives / languages 撑大体积。
rm -rf "$APP/Contents/Resources/language_archives" \
       "$APP/Contents/Resources/languages" || true

VERSION="$(grep -E '^version:' pubspec.yaml | head -1 | awk '{print $2}' | cut -d+ -f1)"
NAME="$(grep -E '^name:' pubspec.yaml | head -1 | awk '{print $2}')"
mkdir -p dist
OUT="dist/${NAME}-${VERSION}-macos.zip"
rm -f "$OUT"
(
  cd "$(dirname "$APP")"
  zip -qry "$ROOT/$OUT" "$(basename "$APP")"
)
echo "==> packaged: $OUT"
ls -lh "$OUT"
du -sh "$APP"
echo "提示：安装包不含语言服务；首次打开对应文件时会弹窗询问是否下载到 Application Support。"
