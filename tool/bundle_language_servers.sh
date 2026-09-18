#!/usr/bin/env bash
# 预置语言服务为 .tar.zst 压缩包（安装包小；运行时首次解压到 Application Support）。
# 用法：
#   ./tool/bundle_language_servers.sh <dest_archives_dir> [all|typescript|pyright|gopls|rust-analyzer|clangd|node]
set -euo pipefail

DEST="${1:-}"
ONLY="${2:-all}"
if [[ -z "$DEST" ]]; then
  echo "usage: $0 <dest_archives_dir> [all|typescript|pyright|gopls|rust-analyzer|clangd|node]" >&2
  exit 1
fi

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing tool: $1" >&2
    return 1
  }
}

need zstd
need tar
need curl

mkdir -p "$DEST"
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/myide-lang.XXXXXX")"
cleanup() { rm -rf "$STAGE"; }
trap cleanup EXIT

OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
ARCH="$(uname -m)"
case "$ARCH" in
  arm64|aarch64) ARCH_RA=aarch64; ARCH_CLANG=arm64; NODE_ARCH=arm64 ;;
  x86_64|amd64) ARCH_RA=x86_64; ARCH_CLANG=x64; NODE_ARCH=x64 ;;
  *) echo "unsupported arch: $ARCH" >&2; exit 1 ;;
esac

should() {
  [[ "$ONLY" == "all" || "$ONLY" == "$1" ]]
}

pack() {
  local folder="$1"
  local src="$STAGE/$folder"
  local out="$DEST/${folder}.tar.zst"
  [[ -d "$src" ]] || return 0
  echo "==> compress $folder -> $out"
  tar -C "$STAGE" -cf - "$folder" | zstd -T0 -19 -f -o "$out"
  ls -lh "$out"
}

install_node() {
  need tar
  local ver="v22.14.0"
  local platform
  if [[ "$OS" == "darwin" ]]; then
    platform="darwin"
  elif [[ "$OS" == "linux" ]]; then
    platform="linux"
  else
    echo "skip portable node on $OS" >&2
    return 0
  fi
  local name="node-${ver}-${platform}-${NODE_ARCH}"
  local url="https://nodejs.org/dist/${ver}/${name}.tar.gz"
  local dir="$STAGE/node"
  mkdir -p "$dir"
  echo "==> download portable node $name"
  curl -fsSL "$url" -o "$STAGE/node.tgz"
  tar -xzf "$STAGE/node.tgz" -C "$STAGE"
  rm -f "$STAGE/node.tgz"

  # 精简：只保留运行 npm/js LS 必需的最小 node，去掉 docs/include 等。
  mkdir -p "$dir/bin"
  cp "$STAGE/$name/bin/node" "$dir/bin/node"
  chmod +x "$dir/bin/node"
  # npm 对部分包不是必须；保留精简 npm 便于调试，但去掉 npx 文档
  if [[ -d "$STAGE/$name/lib/node_modules/npm" ]]; then
    mkdir -p "$dir/lib/node_modules"
    cp -R "$STAGE/$name/lib/node_modules/npm" "$dir/lib/node_modules/npm"
    # npm 入口
    cat > "$dir/bin/npm" <<'EOF'
#!/bin/sh
DIR="$(cd "$(dirname "$0")/.." && pwd)"
exec "$DIR/bin/node" "$DIR/lib/node_modules/npm/bin/npm-cli.js" "$@"
EOF
    chmod +x "$dir/bin/npm"
  fi
  rm -rf "$STAGE/$name"
  # 仅删 build 类目录：保留 .ts/.d.ts/.map/.md/LICENSE 等代码相关文件，
  # 避免 bundled 语言服务缺文件导致编辑器大面积飘红。
  # 体积问题只靠删 build 目录解决。
  find "$dir" -type d \( -name build -o -name dist -o -name out -o -name coverage \) -prune -exec rm -rf {} + 2>/dev/null || true
  echo "node slim: $(du -sh "$dir" | awk '{print $1}')"
}

install_npm_pkg() {
  local folder="$1"; shift
  local bin_name="$1"; shift
  local npm_bin
  if [[ -x "$STAGE/node/bin/npm" ]]; then
    npm_bin="$STAGE/node/bin/npm"
  elif [[ -x "$STAGE/node/bin/node" ]] && [[ -d "$STAGE/node/lib/node_modules/npm" ]]; then
    npm_bin="$STAGE/node/bin/npm"
  else
    need npm
    npm_bin="$(command -v npm)"
  fi
  local dir="$STAGE/$folder"
  mkdir -p "$dir"
  echo "==> npm install $* -> $dir (via $npm_bin)"
  PATH="$(dirname "$npm_bin"):${PATH:-}" \
    "$npm_bin" install --prefix "$dir" --no-fund --no-audit --silent "$@"

  if [[ ! -e "$dir/node_modules/.bin/$bin_name" && ! -e "$dir/node_modules/.bin/$bin_name.cmd" ]]; then
    echo "failed to locate $bin_name after install" >&2
    exit 1
  fi

  # 精简 node_modules：只删 build 类目录，保留 .ts/.d.ts/.map/.md/LICENSE 等代码相关文件
  find "$dir/node_modules" -type d \( -name build -o -name dist -o -name out -o -name coverage \) -prune -exec rm -rf {} + 2>/dev/null || true
  # typescript 只需 lib/tsserver.js 及相关；保留 lib 即可
  if [[ "$folder" == "typescript" ]]; then
    if [[ ! -f "$dir/node_modules/typescript/lib/tsserver.js" ]]; then
      echo "ERROR: tsserver.js missing (pin typescript@5.x)" >&2
      exit 1
    fi
    # 去掉 typescript 里少用的 locale / watchGuard 等可再增强；先保功能
    rm -rf "$dir/node_modules/typescript/bin" 2>/dev/null || true
  fi
  echo "$folder slim: $(du -sh "$dir" | awk '{print $1}')"
}

install_gopls() {
  need go
  local dir="$STAGE/gopls"
  local bin="$dir/bin"
  mkdir -p "$bin"
  echo "==> go install gopls -> $bin"
  GOBIN="$bin" go install golang.org/x/tools/gopls@latest
  test -x "$bin/gopls" || test -f "$bin/gopls.exe"
  # strip
  if command -v strip >/dev/null 2>&1; then
    strip "$bin/gopls" 2>/dev/null || true
  fi
}

install_rust_analyzer() {
  need gzip
  local dir="$STAGE/rust-analyzer"
  local bin="$dir/bin"
  mkdir -p "$bin"
  local asset
  if [[ "$OS" == "darwin" ]]; then
    asset="rust-analyzer-${ARCH_RA}-apple-darwin.gz"
  elif [[ "$OS" == "linux" ]]; then
    asset="rust-analyzer-${ARCH_RA}-unknown-linux-gnu.gz"
  else
    echo "skip rust-analyzer on $OS" >&2
    return 0
  fi
  local url
  url="$(curl -fsSL https://api.github.com/repos/rust-lang/rust-analyzer/releases/latest \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(next(a['browser_download_url'] for a in d['assets'] if a['name']=='''$asset'''))")"
  echo "==> download $asset"
  curl -fsSL "$url" -o "$dir/$asset"
  gzip -df "$dir/$asset"
  mv "$dir/${asset%.gz}" "$bin/rust-analyzer"
  chmod +x "$bin/rust-analyzer"
  if command -v strip >/dev/null 2>&1; then
    strip "$bin/rust-analyzer" 2>/dev/null || true
  fi
}

install_clangd() {
  need unzip
  local dir="$STAGE/clangd"
  mkdir -p "$dir"
  local needle
  if [[ "$OS" == "darwin" ]]; then
    needle="clangd-mac-${ARCH_CLANG}"
  elif [[ "$OS" == "linux" ]]; then
    needle="clangd-linux-${ARCH_CLANG}"
  else
    needle="clangd-windows"
  fi
  local url name
  read -r url name < <(curl -fsSL https://api.github.com/repos/clangd/clangd/releases/latest \
    | python3 -c "import sys,json; d=json.load(sys.stdin); a=next(x for x in d['assets'] if '''$needle''' in x['name'] and x['name'].endswith('.zip')); print(a['browser_download_url'], a['name'])")
  echo "==> download $name"
  curl -fsSL "$url" -o "$dir/$name"
  unzip -qo "$dir/$name" -d "$dir"
  rm -f "$dir/$name"
  # 仅删 build 类目录，保留代码相关文件（避免 bundled 服务缺文件飘红）
  find "$dir" -type d \( -name build -o -name dist -o -name out -o -name coverage \) -prune -exec rm -rf {} + 2>/dev/null || true
  local found
  found="$(find "$dir" -type f \( -name clangd -o -name clangd.exe \) | head -1)"
  test -n "$found"
  chmod +x "$found" || true
}

# node 先装，后续 npm 包可复用
if should node || should all || should typescript || should pyright; then
  install_node || true
fi
if should typescript || should all; then
  install_npm_pkg typescript typescript-language-server \
    typescript-language-server@4.3.3 typescript@5.8.3 || true
fi
if should pyright || should all; then
  install_npm_pkg pyright pyright-langserver pyright@1.1.396 || true
fi
if should gopls || should all; then
  install_gopls || true
fi
if should rust-analyzer || should all; then
  install_rust_analyzer || true
fi
if should clangd || should all; then
  install_clangd || true
fi

# 输出压缩包（不再把解压树塞进 App）
for folder in node typescript pyright gopls rust-analyzer clangd; do
  if [[ -d "$STAGE/$folder" ]]; then
    if should "$folder" || should all || { [[ "$folder" == "node" ]] && { should typescript || should pyright; }; }; then
      pack "$folder"
    fi
  fi
done

echo "==> archives at: $DEST"
ls -lh "$DEST"/*.tar.zst 2>/dev/null || true
