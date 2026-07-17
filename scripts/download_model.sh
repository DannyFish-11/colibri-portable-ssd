#!/usr/bin/env bash
# download_model.sh — 把 GLM-5.2 colibri int4 模型（约 370GB）下载到 SSD
#
# 用法:
#   download_model.sh --ssd /mnt/myssd                 # 下到 <SSD>/model/glm52_i4
#   download_model.sh --ssd /mnt/myssd --repo USER/X   # 换镜像仓库
#
# 断点续传: huggingface_hub 的 snapshot_download 自动跳过已完整的分片，
# 中断后重跑同一条命令即可。需要 python3 + huggingface_hub（脚本可自动安装）。

set -euo pipefail
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"

SSD=""; REPO="${COLI_MODEL_REPO:-mateogrgic/GLM-5.2-colibri-int4-with-int8-mtp}"
while [ $# -gt 0 ]; do
  case "$1" in
    --ssd)   SSD="$2"; shift 2 ;;
    --repo)  REPO="$2"; shift 2 ;;
    *) die "未知参数: $1" ;;
  esac
done
[ -n "$SSD" ] || die "必须指定 --ssd <挂载点>"
DEST="$SSD/model/glm52_i4"

# ---------- 磁盘空间预检 ----------
need_cmd df; need_cmd python3 "请安装 Python 3.10+"
# -P: POSIX 单行输出，避免长设备名折行导致字段错位
AVAIL_KB=$(df -kP "$SSD" | awk 'NR==2{print $4}')
case "$AVAIL_KB" in ''|*[!0-9]*) die "无法解析 $SSD 的可用空间（df 输出异常）" ;; esac
AVAIL_GB=$((AVAIL_KB/1048576))
if [ "$AVAIL_GB" -lt 400 ]; then
  die "$SSD 可用空间约 ${AVAIL_GB}GB，不足 400GB（模型 ~370GB + 余量）。
       上游建议: 真实的本地 NVMe/ext4/NTFS 路径，不要用机械盘或网络盘。"
fi
info "目标: $DEST | 可用 ${AVAIL_GB}GB | 仓库: $REPO"

# ---------- 依赖 ----------
if ! python3 -c "import huggingface_hub" 2>/dev/null; then
  warn "缺 huggingface_hub，尝试自动安装（pip install --user）……"
  python3 -m pip install --user -q huggingface_hub || die "自动安装失败，请手动: pip install huggingface_hub"
fi

mkdir -p "$DEST"
info "开始下载（断点续传，中断后重跑本命令即可）……"
HF_DEST="$DEST" HF_REPO="$REPO" python3 - <<'PY'
import os
from huggingface_hub import snapshot_download
p = snapshot_download(
    repo_id=os.environ["HF_REPO"],
    local_dir=os.environ["HF_DEST"],
    max_workers=8,
)
print("downloaded:", p)
PY

# ---------- 下载后校验 ----------
if [ -x "$HERE/verify_model.sh" ]; then
  "$HERE/verify_model.sh" --model "$DEST"
else
  warn "verify_model.sh 不在旁边，跳过自动校验。"
fi
ok "模型就绪: $DEST"
info "现在可以: $SSD/start.sh"
