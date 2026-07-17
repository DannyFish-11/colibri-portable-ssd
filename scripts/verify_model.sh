#!/usr/bin/env bash
# verify_model.sh — 校验 colibri int4 模型目录的完整性与正确性
#
# 用法:
#   verify_model.sh --model /path/to/glm52_i4           # 完整校验（真实模型）
#   verify_model.sh --model /path/to/fixture --fixture  # 测试夹具模式（跳过体积/MTP 检查）
#
# 检查项:
#   1. config.json / tokenizer.json 存在且可解析
#   2. out-*.safetensors 分片存在；每个分片有合法的 safetensors 头
#   3. 真实模型: 总分片体积 > 300GB（小于此值 = 下载不完整）
#   4. 真实模型: MTP 三件套必须是 int8 尺寸（int4 会让推测解码静默失效）
# 退出码: 0=通过 1=失败

set -euo pipefail
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"

MODEL=""; FIXTURE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --model)   MODEL="$2"; shift 2 ;;
    --fixture) FIXTURE=1; shift ;;
    *) die "未知参数: $1" ;;
  esac
done
[ -n "$MODEL" ] || die "必须指定 --model <目录>"
[ -d "$MODEL" ] || die "目录不存在: $MODEL"
[ -f "$MODEL/.colibri-fixture" ] && FIXTURE=1

FAIL=0
bad() { err "$*"; FAIL=1; }

# ---------- 1. 基础文件 ----------
for f in config.json tokenizer.json; do
  if [ ! -f "$MODEL/$f" ]; then bad "缺文件: $f"; fi
done
if [ "$FAIL" -eq 0 ]; then
  python3 - "$MODEL" <<'PY' || bad "config.json / tokenizer.json 无法解析（文件损坏）"
import json, sys
d = sys.argv[1]
json.load(open(f"{d}/config.json"))
json.load(open(f"{d}/tokenizer.json"))
PY
fi

# ---------- 2. 分片与 safetensors 头 ----------
shopt -s nullglob
SHARDS=("$MODEL"/out-*.safetensors)
shopt -u nullglob
[ ${#SHARDS[@]} -gt 0 ] || bad "没有任何 out-*.safetensors 分片"

if [ ${#SHARDS[@]} -gt 0 ]; then
  python3 - "${SHARDS[@]}" <<'PY' || bad "存在损坏的 safetensors 分片（头不可解析）"
import json, struct, sys
for p in sys.argv[1:]:
    with open(p, "rb") as f:
        raw = f.read(8)
        if len(raw) < 8: raise SystemExit(f"{p}: too small")
        (n,) = struct.unpack("<Q", raw)
        hdr = f.read(n)
        if len(hdr) != n: raise SystemExit(f"{p}: truncated header")
        json.loads(hdr)
PY
fi

# ---------- 3. 体积（仅真实模型） ----------
if [ "$FIXTURE" -eq 0 ] && [ ${#SHARDS[@]} -gt 0 ]; then
  TOTAL_KB=$(du -ck "${SHARDS[@]}" | awk '/total$/{print $1}')
  TOTAL_GB=$((TOTAL_KB/1048576))
  if [ "$TOTAL_GB" -lt 300 ]; then
    bad "分片总体积约 ${TOTAL_GB}GB < 300GB — 下载不完整，重跑 download_model.sh（断点续传）"
  else
    info "分片总体积约 ${TOTAL_GB}GB（${#SHARDS[@]} 个分片）"
  fi
fi

# ---------- 4. MTP 头（仅真实模型） ----------
if [ "$FIXTURE" -eq 0 ]; then
  if check_mtp_heads "$MODEL"; then
    info "MTP 头: int8 正确（推测解码可用，~2x 杠杆）"
  else
    rc=$?
    case $rc in
      1) bad "MTP 头是 int4 版本 — 推测解码接受率为 0%！从 mateogrgic/GLM-5.2-colibri-int4-with-int8-mtp 替换三个 out-mtp-* 文件" ;;
      2) warn "缺 out-mtp-* 文件 — MTP 不可用（能跑，但失去 ~2x 推测解码杠杆）" ;;
      3) bad "out-mtp-* 尺寸无法识别 — 文件可能损坏" ;;
    esac
  fi
fi

if [ "$FAIL" -eq 0 ]; then
  ok "校验通过: $MODEL"
  exit 0
else
  die "校验未通过: $MODEL"
fi
