#!/usr/bin/env bash
# build_webui.sh — 预构建上游 colibri Web UI（React/Vite），把静态产物装进 SSD
#
# 用法: build_webui.sh --ssd /mnt/myssd [--src /path/to/colibri]
#
# 只需要在制作机上跑一次（需要 node >= 18 + npm）；产物是纯静态文件，
# 目标机器零 npm 依赖——serve_ui.py 用 Python 标准库直接托管。

set -euo pipefail
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO_ROOT="$(dirname "$HERE")"
# shellcheck source=lib.sh
. "$HERE/lib.sh"

SSD=""; SRC=""
while [ $# -gt 0 ]; do
  case "$1" in
    --ssd) SSD="$2"; shift 2 ;;
    --src) SRC="$2"; shift 2 ;;
    *) die "未知参数: $1" ;;
  esac
done
[ -n "$SSD" ] || die "必须指定 --ssd <挂载点>"

need_cmd node "安装 Node.js 18+ 后重试（只在制作机上需要）"
need_cmd npm  "安装 npm 后重试"
NODE_MAJOR="$(node -p 'process.versions.node.split(".")[0]')"
[ "$NODE_MAJOR" -ge 18 ] || die "Node.js 版本过低（$(node --version)），需要 >= 18"

# ---------- 源码 ----------
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
if [ -n "$SRC" ]; then
  [ -d "$SRC/web" ] || die "--src 不像 colibri 源码树（缺 web/）: $SRC"
  cp -a "$SRC/web" "$WORK/web"
else
  PIN="$(cat "$REPO_ROOT/PIN" | tr -d '[:space:]')"
  need_cmd curl
  info "获取上游 web/ 源码 @ ${PIN:0:12} ……"
  curl -fsSL --retry 3 --retry-delay 3 \
    "https://codeload.github.com/JustVugg/colibri/tar.gz/$PIN" -o "$WORK/src.tgz" \
    || die "下载失败"
  tar -xzf "$WORK/src.tgz" -C "$WORK"
  cp -a "$WORK/colibri-$PIN/web" "$WORK/web"
fi

# ---------- 构建 ----------
info "npm ci ……"
npm --prefix "$WORK/web" ci --no-audit --no-fund >/dev/null
info "npm test（上游自带测试）……"
npm --prefix "$WORK/web" test >/dev/null
info "npm run build ……"
npm --prefix "$WORK/web" run build >/dev/null
[ -f "$WORK/web/dist/index.html" ] || die "构建失败：缺 dist/index.html"

# ---------- 装配 ----------
mkdir -p "$SSD/webui"
rm -rf "$SSD/webui"
cp -a "$WORK/web/dist" "$SSD/webui"
ok "Web UI 已装配: $SSD/webui（$(du -sh "$SSD/webui" | cut -f1)）"
info "使用: $SSD/start.sh ui   或 GUI 启动器上的 [浏览器界面] 按钮"
