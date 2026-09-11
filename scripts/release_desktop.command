#!/usr/bin/env bash
# 桌面发布：本机可编的平台 → dist/ 扁平打包 → flutter clean
# 依赖 packages/clipboard（path），Windows 可直接 flutter build，无需再 patch。
# 用法：
#   ./scripts/release_desktop.command
#   ./scripts/release_desktop.command --no-clean
#   OUT_DIR=artifacts ./scripts/release_desktop.command
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

NO_CLEAN=0
for arg in "$@"; do
  case "$arg" in
    --no-clean) NO_CLEAN=1 ;;
    -h|--help)
      sed -n '2,8p' "$0"
      exit 0
      ;;
  esac
done

if ! command -v flutter >/dev/null 2>&1; then
  echo "错误：找不到 flutter，请先配置 PATH" >&2
  exit 1
fi

VERSION_LINE="$(grep -E '^version:' pubspec.yaml | head -1 | awk '{print $2}')"
VERSION="${VERSION_LINE%%+*}"
BUILD_NUM="${VERSION_LINE##*+}"
APP_NAME="$(grep -E '^name:' pubspec.yaml | head -1 | awk '{print $2}')"
HOST="$(uname -s | tr '[:upper:]' '[:lower:]')"
ARCH="$(uname -m)"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="${OUT_DIR:-$ROOT/dist}"
mkdir -p "$OUT_DIR"

echo "==> 项目: $APP_NAME  版本: $VERSION+$BUILD_NUM  主机: $HOST/$ARCH"
echo "==> 输出目录: $OUT_DIR"
echo

ok=()
skip=()
fail=()

zip_dir() {
  local src="$1"
  local dest_zip="$2"
  local parent base
  parent="$(dirname "$src")"
  base="$(basename "$src")"
  rm -f "$dest_zip"
  (cd "$parent" && zip -qry "$dest_zip" "$base")
  echo "    已生成: $dest_zip"
}

build_macos() {
  local app_path zip_path
  echo "--> 构建 macOS Release..."
  flutter build macos --release
  app_path="build/macos/Build/Products/Release/${APP_NAME}.app"
  if [[ ! -d "$app_path" ]]; then
    # 少数工程显示名与 package name 不一致，取唯一 .app
    app_path="$(find build/macos/Build/Products/Release -maxdepth 1 -name '*.app' | head -1 || true)"
  fi
  if [[ -z "${app_path:-}" || ! -d "$app_path" ]]; then
    echo "    找不到 .app 产物" >&2
    return 1
  fi
  zip_path="$OUT_DIR/${APP_NAME}-${VERSION}-macos-${ARCH}.zip"
  zip_dir "$ROOT/$app_path" "$zip_path"
  # 同时复制一份未压缩 app 方便本机直接跑（可选）
  # rm -rf "$OUT_DIR/${APP_NAME}-${VERSION}-macos-${ARCH}.app"
  # cp -R "$ROOT/$app_path" "$OUT_DIR/${APP_NAME}-${VERSION}-macos-${ARCH}.app"
  # echo "    已复制: $OUT_DIR/${APP_NAME}-${VERSION}-macos-${ARCH}.app"
}

build_linux() {
  echo "--> 构建 Linux Release..."
  flutter build linux --release
  local bundle="build/linux/x64/release/bundle"
  if [[ ! -d "$bundle" ]]; then
    bundle="$(find build/linux -type d -path '*/release/bundle' | head -1 || true)"
  fi
  if [[ -z "${bundle:-}" || ! -d "$bundle" ]]; then
    echo "    找不到 linux bundle" >&2
    return 1
  fi
  local zip_path="$OUT_DIR/${APP_NAME}-${VERSION}-linux-x64.zip"
  zip_dir "$ROOT/$bundle" "$zip_path"
}

build_windows() {
  echo "--> 构建 Windows Release..."
  flutter build windows --release
  local runner="build/windows/x64/runner/Release"
  if [[ ! -d "$runner" ]]; then
    runner="$(find build/windows -type d -path '*/runner/Release' | head -1 || true)"
  fi
  if [[ -z "${runner:-}" || ! -d "$runner" ]]; then
    echo "    找不到 windows Release 目录" >&2
    return 1
  fi
  local zip_path="$OUT_DIR/${APP_NAME}-${VERSION}-windows-x64.zip"
  zip_dir "$ROOT/$runner" "$zip_path"
}

try_platform() {
  local name="$1"
  local dir="$2"
  local fn="$3"
  if [[ ! -d "$dir" ]]; then
    skip+=("$name(无 $dir 工程)")
    return
  fi
  if "$fn"; then
    ok+=("$name")
  else
    fail+=("$name")
  fi
}

echo "==> flutter pub get"
flutter pub get
echo

case "$HOST" in
  darwin)
    try_platform "macos" "macos" build_macos
    # Flutter 官方不支持在 macOS 上交叉编译 Windows/Linux 桌面产物
    if [[ -d windows ]]; then
      skip+=("windows(需在 Windows 主机执行本脚本)")
    fi
    if [[ -d linux ]]; then
      skip+=("linux(需在 Linux 主机执行本脚本)")
    fi
    ;;
  linux)
    try_platform "linux" "linux" build_linux
    if [[ -d macos ]]; then
      skip+=("macos(需在 macOS 主机执行本脚本)")
    fi
    if [[ -d windows ]]; then
      skip+=("windows(需在 Windows 主机执行本脚本)")
    fi
    ;;
  msys*|mingw*|cygwin*|windows*)
    try_platform "windows" "windows" build_windows
    if [[ -d macos ]]; then
      skip+=("macos(需在 macOS 主机执行本脚本)")
    fi
    if [[ -d linux ]]; then
      skip+=("linux(需在 Linux 主机执行本脚本)")
    fi
    ;;
  *)
    echo "未识别主机: $HOST" >&2
    exit 1
    ;;
esac

echo
cat > "$OUT_DIR/BUILD_INFO-${STAMP}.txt" <<INFO
app=$APP_NAME
version=$VERSION+$BUILD_NUM
host=$HOST/$ARCH
built_at=$STAMP
ok=${ok[*]:-}
skip=${skip[*]:-}
fail=${fail[*]:-}
INFO

echo "==> 发布结果"
echo "  成功: ${ok[*]:-无}"
echo "  跳过: ${skip[*]:-无}"
echo "  失败: ${fail[*]:-无}"
echo "  产物目录: $OUT_DIR"
ls -lh "$OUT_DIR" | sed 's/^/  /'
echo

if [[ "$NO_CLEAN" -eq 0 ]]; then
  echo "==> 清理 build 缓存 (flutter clean)"
  flutter clean
  echo "完成。"
else
  echo "==> 已跳过 flutter clean (--no-clean)"
fi

if [[ ${#fail[@]} -gt 0 ]]; then
  exit 1
fi
