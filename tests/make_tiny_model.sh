#!/usr/bin/env bash
# make_tiny_model.sh — 生成 ~170MB 的 int4 测试夹具模型（结构与真实 GLM-5.2 同构）
#
# 用法: make_tiny_model.sh --src /path/to/colibri --out /path/to/glm_bench_i4
#
# 流程（全部使用上游官方工具）:
#   1. tools/make_glm_bench_model.py --fp8   生成随机权重 FP8 夹具（布局同真实 FP8 检查点）
#   2. tools/convert_fp8_to_int4.py          转成引擎的 int4 容器（走的真实转换路径）
#   3. tests/gen_tokenizer.py                合成结构合法的 tokenizer.json + eos 配置
#   4. 写入 .colibri-fixture 标记（verify/start 据此放宽体积与内存检查）
#
# 依赖: python3 + torch(CPU 版即可) + transformers(>=含 GlmMoeDsa 的版本) + safetensors

set -euo pipefail
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# shellcheck source=../scripts/lib.sh
. "$HERE/../scripts/lib.sh"

SRC=""; OUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --src) SRC="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    *) die "未知参数: $1" ;;
  esac
done
[ -n "$SRC" ] || die "必须指定 --src <colibri 源码目录>"
[ -n "$OUT" ] || die "必须指定 --out <输出目录>"
[ -f "$SRC/c/tools/make_glm_bench_model.py" ] || die "--src 不像 colibri 源码树: $SRC"

need_cmd python3
python3 -c "import torch, transformers, safetensors" 2>/dev/null \
  || die "缺依赖: pip install torch --index-url https://download.pytorch.org/whl/cpu && pip install transformers safetensors"
python3 -c "from transformers import GlmMoeDsaConfig" 2>/dev/null \
  || die "transformers 版本太旧，不含 GlmMoeDsaConfig，请升级 transformers"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
info "1/4 生成 FP8 夹具（随机权重，仅用于测试管线，不是语言模型）……"
python3 "$SRC/c/tools/make_glm_bench_model.py" --fp8 --output "$WORK/fp8" >/dev/null

info "2/4 转换 int4 容器（真实转换路径）……"
python3 "$SRC/c/tools/convert_fp8_to_int4.py" --indir "$WORK/fp8" --outdir "$OUT" \
  --ebits 4 --group-size 128 >/dev/null

info "3/4 合成 tokenizer 与 eos 配置……"
python3 "$HERE/gen_tokenizer.py" "$OUT" >/dev/null

info "4/4 写入夹具标记……"
echo "colibri test fixture - not a language model" > "$OUT/.colibri-fixture"

ok "夹具就绪: $OUT ($(du -sh "$OUT" | cut -f1))"
