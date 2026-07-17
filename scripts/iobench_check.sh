#!/usr/bin/env bash
# iobench_check.sh — 用上游 iobench 实测这块 SSD 在当前机器上的随机读速度，并给出判定
#
# 用法:
#   iobench_check.sh --ssd /mnt/myssd
#   iobench_check.sh --model /path/to/glm52_i4        # 不指定 SSD 时直接给模型目录
#
# 引擎的磁盘用法是"并行 19MB 随机读"，iobench 精确复现这个模式。
# 判定基线（来自上游 README 与社区实测）:
#   ~1 GB/s  = 作者开发机基线（冷态 ~0.05-0.1 tok/s，能跑）
#   3-5 GB/s = 原生 PCIe4 NVMe（~0.5-1 tok/s）
#   8+ GB/s  = PCIe5 / RAID0（~2-4 tok/s 量级）

set -euo pipefail
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"

SSD=""; MODEL=""
while [ $# -gt 0 ]; do
  case "$1" in
    --ssd)   SSD="$2"; shift 2 ;;
    --model) MODEL="$2"; shift 2 ;;
    *) die "未知参数: $1" ;;
  esac
done
[ -z "$MODEL" ] && [ -n "$SSD" ] && MODEL="$SSD/model/glm52_i4"
[ -n "$MODEL" ] || die "必须指定 --ssd 或 --model"
[ -d "$MODEL" ] || die "模型目录不存在: $MODEL"

# ---------- 找 iobench ----------
IOBENCH=""
CANDIDATES=()
[ -n "$SSD" ] && CANDIDATES+=("$SSD/bin/iobench")
CANDIDATES+=("$HERE/../bin/iobench" "$(dirname "$HERE")/bin/iobench" "$HERE/iobench")
for c in "${CANDIDATES[@]}"; do
  [ -x "$c" ] && IOBENCH="$c" && break
done
if [ -z "$IOBENCH" ]; then
  need_cmd gcc
  info "未找到预编译 iobench，现从上游源码编译……"
  TMPD="$(mktemp -d)"; trap 'rm -rf "$TMPD"' EXIT
  need_cmd curl
  curl -fsSL https://raw.githubusercontent.com/JustVugg/colibri/main/c/iobench.c -o "$TMPD/iobench.c" \
    || die "下载 iobench.c 失败"
  gcc -O2 -fopenmp "$TMPD/iobench.c" -o "$TMPD/iobench"
  IOBENCH="$TMPD/iobench"
fi

# ---------- 选一个没碰过的分片 ----------
shopt -s nullglob
SHARDS=("$MODEL"/out-*.safetensors)
shopt -u nullglob
[ ${#SHARDS[@]} -gt 0 ] || die "模型目录没有 out-*.safetensors 分片: $MODEL"
SHARD="${SHARDS[0]}"

info "测速对象: $SHARD"
info "模式: 19MB x 64 次随机读, 8 线程（与引擎冷态专家加载同构）"

run_bench() { # $1=0 buffered / 1=O_DIRECT -> 输出原始行
  "$IOBENCH" "$SHARD" 19 64 8 "$1" 2>&1 | tail -5
}

echo "---- buffered（含页缓存影响，偏乐观）----" >&2
OUT_BUF="$(run_bench 0)"; echo "$OUT_BUF" >&2
echo "---- O_DIRECT（真实盘速，看这个）----"   >&2
OUT_DIR="$(run_bench 1)"; echo "$OUT_DIR" >&2

# 从输出里抠 GB/s（iobench 输出格式含 "X.XX GB/s" 或 "XXX MB/s"）
extract_gbs() {
  echo "$1" | grep -oE '[0-9]+(\.[0-9]+)? *(GB/s|MB/s)' | tail -1 | awk '
    /GB\/s/ {printf "%.2f", $1; exit}
    /MB\/s/ {printf "%.2f", $1/1024; exit}'
}
GBS="$(extract_gbs "$OUT_DIR")"
[ -z "$GBS" ] && GBS="$(extract_gbs "$OUT_BUF")"
[ -n "$GBS" ] || die "无法解析 iobench 输出，请把上面的原始输出发到仓库 issue"

echo >&2
info "实测随机读: ${GBS} GB/s（O_DIRECT 优先）"
V="$(awk -v g="$GBS" 'BEGIN{
  if (g < 0.45)      {print "slow";      exit}
  if (g < 1.5)       {print "baseline";  exit}
  if (g < 3.5)       {print "good";      exit}
                     {print "excellent"; exit}
}')"
case "$V" in
  slow)
    warn "判定: 太慢（<0.45 GB/s）— 可能是 USB 3.0/机械盘/劣质硬盘盒。
         冷态会慢到不可用。建议换 USB4/雷电硬盘盒或直连 NVMe。" ;;
  baseline)
    ok "判定: 达到作者开发机基线（~1 GB/s 级）。
         冷态 ~0.05-0.1 tok/s（第一句按分钟等），热缓存后明显改善。可用。" ;;
  good)
    ok "判定: 良好（1.5-3.5 GB/s，USB4/雷电或原生 PCIe4 级）。
         冷态明显好于基线，热缓存后接近可用聊天体验。" ;;
  excellent)
    ok "判定: 优秀（>3.5 GB/s，原生 PCIe4/5 级）。
         预期冷态 ~0.3-1 tok/s，热缓存 + pin 后更好。" ;;
esac
