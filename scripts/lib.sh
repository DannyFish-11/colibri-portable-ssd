# shellcheck shell=bash
# lib.sh — colibri-portable-ssd 公共函数库
# 被 start.sh / coli-ssd / 各脚本 source。只定义函数与变量，不执行动作。

# ---------- 日志 ----------
if [ -t 2 ] && [ -z "${COLI_NO_COLOR:-}" ]; then
  _C_RED=$'\033[31m'; _C_YEL=$'\033[33m'; _C_GRN=$'\033[32m'
  _C_CYN=$'\033[36m'; _C_DIM=$'\033[2m';  _C_RST=$'\033[0m'
else
  _C_RED=''; _C_YEL=''; _C_GRN=''; _C_CYN=''; _C_DIM=''; _C_RST=''
fi
info() { printf '%s[*]%s %s\n' "$_C_CYN" "$_C_RST" "$*" >&2; }
ok()   { printf '%s[+]%s %s\n' "$_C_GRN" "$_C_RST" "$*" >&2; }
warn() { printf '%s[!]%s %s\n' "$_C_YEL" "$_C_RST" "$*" >&2; }
err()  { printf '%s[x]%s %s\n' "$_C_RED" "$_C_RST" "$*" >&2; }
die()  { err "$*"; exit 1; }

need_cmd() { command -v "$1" >/dev/null 2>&1 || die "缺少命令: $1 — $2"; }

# ---------- 路径 ----------
# 解析某个脚本自身所在的绝对目录（穿透符号链接），不受调用者 cwd 影响。
script_dir_of() {
  local src="$1"
  while [ -h "$src" ]; do
    local d; d="$(cd -P "$(dirname "$src")" >/dev/null 2>&1 && pwd)"
    src="$(readlink "$src")"
    case "$src" in /*) ;; *) src="$d/$src";; esac
  done
  cd -P "$(dirname "$src")" >/dev/null 2>&1 && pwd
}

# ---------- 平台 ----------
# 输出形如 linux-x86_64 / darwin-arm64 / darwin-x86_64
detect_platform() {
  local os arch
  os="$(uname -s)"; arch="$(uname -m)"
  case "$os" in
    Linux)  os=linux ;;
    Darwin) os=darwin ;;
    *)      die "不支持的操作系统: $os（Windows 请用 start.bat）" ;;
  esac
  case "$arch" in
    x86_64|amd64) arch=x86_64 ;;
    arm64|aarch64) arch=arm64 ;;
    *) die "不支持的 CPU 架构: $arch" ;;
  esac
  printf '%s-%s' "$os" "$arch"
}

# x86 上必须有 AVX2（上游便携构建的底线）；arm64 无此概念，直接通过。
check_avx2() {
  case "$(uname -m)" in
    x86_64|amd64)
      if [ "$(uname -s)" = "Linux" ]; then
        grep -qm1 avx2 /proc/cpuinfo 2>/dev/null \
          || die "CPU 不支持 AVX2 — colibri 的 x86 便携构建无法在此机运行"
      elif [ "$(uname -s)" = "Darwin" ]; then
        sysctl -a 2>/dev/null | grep -qm1 'machdep.cpu.*AVX2' \
          || die "CPU 不支持 AVX2 — colibri 无法在此机运行"
      fi
      ;;
  esac
  return 0
}

# ---------- 内存 ----------
# 输出可用内存 GB（整数）。Linux 取 MemAvailable；macOS 取物理内存总量
# （unified memory 下总量比"空闲"更有参考意义，结果仅用于提示）。
avail_ram_gb() {
  if [ "$(uname -s)" = "Linux" ]; then
    awk '/MemAvailable/ {printf "%d", $2/1048576; exit}' /proc/meminfo
  elif [ "$(uname -s)" = "Darwin" ]; then
    echo $(( $(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1073741824 ))
  else
    echo 0
  fi
}

# 内存门槛。$1=模型目录。COLI_MIN_RAM_GB 可覆盖（测试/夹具用 0）。
check_ram() {
  local model_dir="$1" min="${COLI_MIN_RAM_GB:-16}" have
  if [ -f "$model_dir/.colibri-fixture" ] && [ -z "${COLI_MIN_RAM_GB:-}" ]; then
    min=1   # 测试夹具模型只有 ~170MB，放宽门槛
  fi
  have="$(avail_ram_gb)"
  [ "$have" -ge "$min" ] && return 0
  if [ "$min" -le 1 ]; then return 0; fi
  die "可用内存约 ${have}GB，低于门槛 ${min}GB。
       GLM-5.2 int4 的稠密部分常驻 ~9.9GB，聊天峰值 RSS ~20GB；
       建议可用内存 >=25GB。确认要用小内存硬跑，可设 COLI_MIN_RAM_GB=0 重试（可能触发 swap 甚至 OOM，后果自负）。"
}

# ---------- 模型 ----------
# int8 MTP 三件套的正确尺寸（来自上游 README；int4 尺寸会导致 MTP 0% 接受率）
MTP_INT8_SIZES="3527131672 5366238584 1065950496"
MTP_INT4_SIZES="1765523544 2686077736 536747200"

# 检查 MTP 头是否为 int8。返回: 0=int8 正确 / 1=int4 错误 / 2=缺失 / 3=尺寸异常
check_mtp_heads() {
  local dir="$1" f sizes="" s
  shopt -s nullglob
  local files=("$dir"/out-mtp-*.safetensors)
  shopt -u nullglob
  [ ${#files[@]} -eq 0 ] && return 2
  for f in "${files[@]}"; do
    s=$(wc -c < "$f" | tr -d ' ')
    sizes="$sizes $s"
  done
  sizes="$(echo "$sizes" | sed 's/^ //')"
  [ "$sizes" = "$MTP_INT8_SIZES" ] && return 0
  [ "$sizes" = "$MTP_INT4_SIZES" ] && return 1
  return 3
}

file_size_human() { du -h "$1" 2>/dev/null | cut -f1; }
