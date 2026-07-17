#!/usr/bin/env bash
# build_engine.sh — 从上游 colibri（锁定 commit）构建当前平台的引擎，装入 SSD 目录树
#
# 用法:
#   build_engine.sh --ssd /mnt/myssd              # 克隆 PIN 版本 → 构建 → 装配
#   build_engine.sh --ssd /mnt/myssd --src /path/to/colibri   # 用本地检出的源码（离线/调试用）
#
# 产物（写入 SSD）:
#   <SSD>/engine/<platform>/{coli, glm, *.py, tools/, ...}   运行时引擎（原地可运行布局）
#   <SSD>/bin/iobench                                        盘速测试工具
#   <SSD>/start.sh <SSD>/start.bat <SSD>/scripts/lib.sh ...  启动器与脚本
#   <SSD>/gui/colibri_ssd.py                                 图形启动器
#   <SSD>/model/                                             模型占位目录
#
# 上游许可证: Apache-2.0（随引擎附带 LICENSE 与来源声明）。

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

PIN="$(cat "$REPO_ROOT/PIN" 2>/dev/null | tr -d '[:space:]')"
[ -n "$PIN" ] || die "仓库根目录缺 PIN 文件（上游 colibri 的锁定 commit）"

PLATFORM="$(detect_platform)"
info "目标平台: $PLATFORM | 上游 colibri @ ${PIN:0:12}"

# ---------- 1. 获取源码 ----------
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
if [ -n "$SRC" ]; then
  [ -d "$SRC/c" ] || die "--src 指向的目录不像 colibri 源码树（缺 c/ 子目录）: $SRC"
  info "使用本地源码: $SRC"
  cp -a "$SRC/." "$WORK/colibri/"
else
  need_cmd git "安装 git 后重试"
  info "克隆上游 colibri（浅克隆指定 commit）……"
  mkdir -p "$WORK/colibri"
  git -C "$WORK/colibri" init -q
  git -C "$WORK/colibri" remote add origin https://github.com/JustVugg/colibri
  FETCHED=0
  for attempt in 1 2 3; do
    if git -C "$WORK/colibri" fetch -q --depth 1 origin "$PIN"; then FETCHED=1; break; fi
    warn "git fetch 第 $attempt 次失败（网络抖动？），重试……"
    sleep 3
  done
  if [ "$FETCHED" -eq 1 ]; then
    git -C "$WORK/colibri" checkout -q FETCH_HEAD
  else
    # git 协议走不通时的兜底：codeload 源码 tarball（同一 commit，不同端点）
    warn "git fetch 连续失败，改用 codeload tarball 兜底……"
    need_cmd curl "git 与 curl 都不可用，无法获取源码"
    curl -fsSL --retry 3 --retry-delay 3 \
      "https://codeload.github.com/JustVugg/colibri/tar.gz/$PIN" -o "$WORK/src.tgz" \
      || die "codeload 也失败 — 检查网络/代理后重跑"
    tar -xzf "$WORK/src.tgz" -C "$WORK"
    mv "$WORK/colibri-$PIN"/* "$WORK/colibri/"
    rm -rf "$WORK/colibri-$PIN" "$WORK/src.tgz"
  fi
  [ -f "$WORK/colibri/c/glm.c" ] || die "源码获取失败：缺 c/glm.c"
fi

# ---------- 2. 构建 ----------
need_cmd gcc "安装 gcc（含 OpenMP）后重试：Debian/Ubuntu: apt install build-essential"
info "构建引擎（make）……"
make -C "$WORK/colibri" >/dev/null
[ -x "$WORK/colibri/c/glm" ] || die "构建失败：没有产出 c/glm"
ok "引擎构建完成: $(du -h "$WORK/colibri/c/glm" | cut -f1)"

info "构建 iobench……"
gcc -O2 -fopenmp "$WORK/colibri/c/iobench.c" -o "$WORK/colibri/c/iobench"

# ---------- 3. 装配 SSD 目录树 ----------
info "装配到 $SSD ……"
mkdir -p "$SSD/engine/$PLATFORM" "$SSD/bin" "$SSD/scripts" "$SSD/model"

# 引擎：原地可运行布局 = coli + glm + python 支撑模块 + tools/（convert/bench 需要）
cp "$WORK/colibri/c/coli"   "$SSD/engine/$PLATFORM/"
cp "$WORK/colibri/c/glm"    "$SSD/engine/$PLATFORM/"
cp "$WORK/colibri/c"/*.py   "$SSD/engine/$PLATFORM/"
rm -rf "$SSD/engine/$PLATFORM/tools"
mkdir -p "$SSD/engine/$PLATFORM/tools"
cp "$WORK/colibri/c/tools"/*.py "$SSD/engine/$PLATFORM/tools/" 2>/dev/null || true
# 上游许可与来源（Apache-2.0 要求保留声明）
cp "$WORK/colibri/LICENSE"  "$SSD/engine/$PLATFORM/LICENSE.upstream"
printf 'engine: https://github.com/JustVugg/colibri\ncommit: %s\nbuilt: %s\nplatform: %s\n' \
  "$PIN" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$PLATFORM" > "$SSD/engine/$PLATFORM/PROVENANCE"

cp "$WORK/colibri/c/iobench" "$SSD/bin/iobench"

# 启动器与脚本（脚本始终与仓库同步一份到 SSD，保证插上就是最新版逻辑）
cp "$HERE/start.sh"    "$SSD/start.sh";    chmod +x "$SSD/start.sh"
cp "$HERE/start.bat"   "$SSD/start.bat" 2>/dev/null || true
cp "$HERE/lib.sh"      "$SSD/scripts/"
cp "$HERE/iobench_check.sh" "$SSD/scripts/" 2>/dev/null || true
cp "$HERE/verify_model.sh"  "$SSD/scripts/" 2>/dev/null || true
cp "$HERE/serve_ui.py"      "$SSD/scripts/" 2>/dev/null || true
chmod +x "$SSD/scripts"/*.sh 2>/dev/null || true
# GUI 启动器（tkinter 零依赖）
if [ -d "$REPO_ROOT/gui" ]; then
  mkdir -p "$SSD/gui"
  cp "$REPO_ROOT/gui/colibri_ssd.py" "$SSD/gui/"
fi

cat > "$SSD/README-FIRST.txt" <<'EOF'
colibri-portable-ssd — 即插即用 AI SSD
=====================================
1. 下载模型（一次性，约 370GB，可断点续传）:
     coli-ssd download --ssd <这块盘的挂载点>
   或任意机器上直接运行本盘 scripts/ 里的 download_model.sh。
2. 每次使用:
     Linux/macOS:  ./start.sh            （./start.sh --readonly 为纯只读模式）
     浏览器界面:    ./start.sh ui
     图形启动器:    python3 gui/colibri_ssd.py
     Windows:      start.bat
3. 用完正常退出聊天，再安全弹出。模型分片全程只读，不会写坏。
EOF

ok "装配完成。目录树："
find "$SSD" -maxdepth 2 -not -path '*/engine/*' | sed "s|$SSD|<SSD>|" >&2
echo >&2
info "下一步: coli-ssd download --ssd \"$SSD\"   # 下载 370GB 模型（可断点续传）"
