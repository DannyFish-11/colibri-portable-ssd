#!/usr/bin/env bash
# start.sh — colibri-portable-ssd 即插即用启动器（Linux / macOS）
#
# 放在 SSD 根目录。插上电脑后：
#     ./start.sh                # 交互聊天（默认）
#     ./start.sh run "提示词"    # 单次生成
#     ./start.sh serve          # OpenAI 兼容 API
#     ./start.sh ui             # 浏览器界面（API + Web UI + 自动开浏览器）
#     ./start.sh plan / doctor  # 资源规划 / 体检
#     ./start.sh --readonly     # 纯只读模式（KVSAVE=0，不向 SSD 写任何状态）
#     ./start.sh --bench        # 先测这块盘在这台机器上的真实速度
#
# 本脚本不依赖调用时的 cwd；路径全部相对于脚本自身解析。

set -euo pipefail
ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# 允许仓库内运行：scripts/start.sh 时 ROOT 上溯一级
if [ -f "$ROOT/scripts/lib.sh" ]; then
  SRC="$ROOT/scripts"
else
  SRC="$ROOT"
  ROOT="$(dirname "$ROOT")"
fi
# shellcheck source=lib.sh
. "$SRC/lib.sh"

# ---------- 参数 ----------
READONLY=0; DO_BENCH=0
ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --readonly|--ro) READONLY=1; shift ;;
    --bench)         DO_BENCH=1; shift ;;
    -h|--help)
      sed -n '2,13p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) ARGS+=("$1"); shift ;;
  esac
done
[ ${#ARGS[@]} -eq 0 ] && ARGS=(chat)

PLATFORM="$(detect_platform)"
ENGINE="$ROOT/engine/$PLATFORM"
MODEL_DIR="${COLI_MODEL_DIR:-$ROOT/model/glm52_i4}"

# ---------- 自检 ----------
[ -x "$ENGINE/coli" ] || die "找不到本机平台的引擎: $ENGINE/coli
       这块 SSD 还没有 $PLATFORM 平台的引擎。在有网络的机器上运行：
         coli-ssd build --ssd \"$ROOT\"
       支持的平台目录: linux-x86_64 / darwin-arm64 / darwin-x86_64 / windows-x86_64"

need_cmd python3 "colibri 的 CLI 是 Python 写的，引擎本体是 C。请安装 Python 3.10+"

if [ ! -d "$MODEL_DIR" ]; then
  die "模型目录不存在: $MODEL_DIR
       请先下载模型（约 370GB，可断点续传）：
         coli-ssd download --ssd \"$ROOT\"
       或指定已有模型目录：COLI_MODEL_DIR=/path/to/glm52_i4 ./start.sh"
fi
[ -f "$MODEL_DIR/config.json" ]    || die "模型目录缺 config.json: $MODEL_DIR（下载不完整？重新运行 coli-ssd download）"
[ -f "$MODEL_DIR/tokenizer.json" ] || die "模型目录缺 tokenizer.json: $MODEL_DIR（下载不完整？重新运行 coli-ssd download）"
ls "$MODEL_DIR"/out-*.safetensors >/dev/null 2>&1 \
  || die "模型目录没有任何 out-*.safetensors 分片: $MODEL_DIR（下载不完整？重新运行 coli-ssd download）"

check_avx2
check_ram "$MODEL_DIR"

# MTP 头体检（int4 头会让推测解码静默失效）
if [ ! -f "$MODEL_DIR/.colibri-fixture" ]; then
  if check_mtp_heads "$MODEL_DIR"; then
    :
  else
    rc=$?
    case $rc in
      1) warn "MTP 头是 int4 版本 — 推测解码接受率将为 0%（白白慢 ~2x）。"
         warn "请从 mateogrgic/GLM-5.2-colibri-int4-with-int8-mtp 替换三个 out-mtp-* 文件。" ;;
      2) warn "未找到 out-mtp-* 文件 — MTP 推测解码不可用（仍能跑，只是慢）。" ;;
      3) warn "out-mtp-* 尺寸无法识别 — 文件可能损坏，建议 coli-ssd verify。" ;;
    esac
  fi
fi

# ---------- 环境 ----------
export COLI_MODEL="$MODEL_DIR"
if [ "$READONLY" -eq 1 ]; then
  export KVSAVE=0            # 不写 .coli_kv（会话 KV 缓存）
  export COLI_USAGE=0        # 不写 .coli_usage（学习缓存）；引擎不识别此变量也无害
  info "纯只读模式：KVSAVE=0，SSD 上不会产生会话写入（学习缓存也不会累积）。"
fi

# ---------- 可选：先测盘速 ----------
if [ "$DO_BENCH" -eq 1 ]; then
  if [ -x "$SRC/iobench_check.sh" ]; then
    "$SRC/iobench_check.sh" --ssd "$ROOT" || warn "盘速测试未通过，继续启动……"
  else
    warn "iobench_check.sh 不在 SSD 上，跳过测速。"
  fi
fi

PLAT_NOTE=""
case "$PLATFORM" in darwin-*) PLAT_NOTE="（macOS: 如遇 Gatekeeper 拦截，先运行 xattr -dr com.apple.quarantine \"$ROOT\"）" ;; esac
info "平台 $PLATFORM | 模型 $MODEL_DIR $PLAT_NOTE"
[ "$READONLY" -eq 1 ] || info "提示：./start.sh --readonly 可全程不写 SSD；用完正常退出后即可安全拔出。"

# ---------- 浏览器界面快捷方式 ----------
# ./start.sh ui = 启动 API + 托管 Web UI + 自动开浏览器
if [ "${ARGS[0]}" = "ui" ]; then
  WEBUI="$ROOT/webui"
  [ -f "$WEBUI/index.html" ] || die "Web UI 未构建（$WEBUI 缺 index.html）。
       在有 node/npm 的制作机上运行: scripts/build_webui.sh --ssd \"$ROOT\""
  RO_FLAG=()
  [ "$READONLY" -eq 1 ] && RO_FLAG=(--readonly)
  exec python3 "$SRC/serve_ui.py" --engine "$ENGINE" --model "$MODEL_DIR" --webui "$WEBUI" "${RO_FLAG[@]}"
fi

# ---------- 启动 ----------
# noexec 挂载探测（Linux）：外置盘若被 noexec 挂载，引擎二进制将无法执行
if [ "$(uname -s)" = "Linux" ] && command -v findmnt >/dev/null 2>&1; then
  if findmnt -no OPTIONS --target "$ENGINE" 2>/dev/null | grep -qw noexec; then
    die "SSD 以 noexec 挂载，引擎无法执行。
       修复: sudo mount -o remount,exec \"$(findmnt -no TARGET --target "$ENGINE")\"
       或把 $ENGINE 复制到本地磁盘后设 COLI_ENGINE 再运行。"
  fi
fi
cd "$ENGINE"
exec python3 "$ENGINE/coli" "${ARGS[@]}"
