#!/usr/bin/env bash
# install.sh — 一键制作即插即用 AI SSD（总入口）
#
# 用法:
#   ./install.sh --ssd /mnt/myssd                    # 全流程：引擎+WebUI+模型下载+总检
#   ./install.sh --ssd /mnt/myssd --skip-download    # 只装引擎和界面，模型以后再说
#   ./install.sh --ssd /mnt/myssd --dry-run          # 只打印计划，不动手
#
# 制作完成后，这块 SSD 插到任何满足条件的电脑（≥25GB 内存建议 / AVX2 / Python3）：
#   Linux/macOS:  ./start.sh            Windows: start.bat     图形界面: gui/colibri_ssd.py

set -euo pipefail
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# shellcheck source=scripts/lib.sh
. "$HERE/scripts/lib.sh"

SSD=""; SKIP_DL=0; DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --ssd)           SSD="$2"; shift 2 ;;
    --skip-download) SKIP_DL=1; shift ;;
    --dry-run)       DRY=1; shift ;;
    -h|--help)       sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "未知参数: $1（--help 查看用法）" ;;
  esac
done
[ -n "$SSD" ] || die "必须指定 --ssd <SSD挂载点>"
[ -d "$SSD" ] || die "路径不存在: $SSD（先把 SSD 挂载好）"

echo "===============================" >&2
echo " colibri-portable-ssd 一键制作" >&2
echo " 目标: $SSD" >&2
echo "===============================" >&2

STEPS=(
  "1/4 构建推理引擎（上游锁定 commit）"
  "2/4 预构建浏览器界面（可选但推荐）"
  "3/4 下载 GLM-5.2 int4 模型 ~370GB$([ $SKIP_DL -eq 1 ] && echo '【跳过】')"
  "4/4 一键总检（引擎+模型+盘速）"
)
for s in "${STEPS[@]}"; do info "$s"; done
[ "$DRY" -eq 1 ] && { ok "dry-run 结束：以上就是要做的事。去掉 --dry-run 正式执行。"; exit 0; }

# 1. 引擎
"$HERE/scripts/coli-ssd" build --ssd "$SSD"

# 2. Web UI（node 不在就跳过，不阻塞主流程）
if command -v node >/dev/null 2>&1 && command -v npm >/dev/null 2>&1; then
  "$HERE/scripts/build_webui.sh" --ssd "$SSD" || warn "Web UI 构建失败（不影响命令行使用，可后补）"
else
  warn "未检测到 node/npm — 跳过浏览器界面（不影响命令行；装上 node 后可跑 build_webui.sh 补装）"
fi

# 3. 模型
if [ "$SKIP_DL" -eq 1 ]; then
  warn "按 --skip-download 跳过模型下载。以后补下: scripts/coli-ssd download --ssd \"$SSD\""
else
  "$HERE/scripts/coli-ssd" download --ssd "$SSD"
fi

# 4. 总检
if [ "$SKIP_DL" -eq 1 ]; then
  warn "模型未下载，跳过总检。模型下好后执行: scripts/coli-ssd doctor --ssd \"$SSD\""
else
  "$HERE/scripts/coli-ssd" doctor --ssd "$SSD"
fi

echo >&2
ok "制作完成！"
echo >&2
echo "  日常使用：" >&2
echo "    Linux/macOS:  $SSD/start.sh" >&2
echo "    Windows:      $SSD\\start.bat" >&2
echo "    图形界面:     python3 $SSD/gui/colibri_ssd.py" >&2
echo "    浏览器界面:   $SSD/start.sh ui" >&2
