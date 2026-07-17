#!/usr/bin/env bash
# e2e_tiny.sh — colibri-portable-ssd 端到端测试（不需要 370GB 模型）
#
# 用法: tests/e2e_tiny.sh [--src /path/to/colibri] [--keep]
#
# 覆盖:
#   1. 全部脚本 bash 语法检查
#   2. build_engine.sh 装配引擎（本地源码 + 真实 git PIN 克隆两条路径）
#   3. 夹具模型 → start.sh run 真实推理（含路径带空格的 SSD 模拟）
#   4. --readonly 纯只读模式：模型目录不可写时不产生任何状态文件
#   5. verify_model.sh 正向/负向用例
#   6. iobench_check.sh 实测与判定输出
#   7. 缺模型时的错误提示质量（负向）
#   8. coli-ssd doctor 在半成品 SSD 上正确报错（负向）
#   9. GUI 启动器检测逻辑（无头）
#  10. start.sh ui 冒烟（真实 API + 静态站）
#  11. shellcheck 零告警
#  12. install.sh 参数与 dry-run
#  13. --help 输出不混入代码行（start.sh / coli-ssd / install.sh 回归）
#  14. serve_ui 退出码：引擎缺失=干净报错 1；健康检查超时=1（不得伪装成 0）

set -uo pipefail
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO="$(dirname "$HERE")"
# shellcheck source=../scripts/lib.sh
. "$REPO/scripts/lib.sh"

SRC=""; KEEP=0
while [ $# -gt 0 ]; do
  case "$1" in
    --src)  SRC="$2"; shift 2 ;;
    --keep) KEEP=1; shift ;;
    *) die "未知参数: $1" ;;
  esac
done
[ -n "$SRC" ] || SRC="${COLIBRI_SRC:-/tmp/colibri}"
[ -d "$SRC/c" ] || die "找不到 colibri 源码（--src 或 COLIBRI_SRC）: $SRC"

PASS=0; FAILT=0
t_ok()   { ok   "T$1 PASS — $2"; PASS=$((PASS+1)); }
t_fail() { err  "T$1 FAIL — $2"; FAILT=$((FAILT+1)); }
t_run()  { # t_run <n> <描述> <命令...>
  local n="$1" d="$2"; shift 2
  info "T$n: $d"
  if "$@" >/tmp/e2e_t$n.log 2>&1; then t_ok "$n" "$d"; else
    t_fail "$n" "$d（日志 /tmp/e2e_t$n.log）"; sed 's/^/    | /' /tmp/e2e_t$n.log >&2
  fi
}

BASE="$(mktemp -d /tmp/coli-ssd-e2e.XXXXXX)"
SSD="$BASE/fake ssd 带空格"      # 故意带空格，考验全部路径引用
mkdir -p "$SSD"
[ "$KEEP" -eq 1 ] || trap 'rm -rf "$BASE"' EXIT
info "测试工作区: $SSD"

# ---------- T1: 语法 ----------
t_run 1 "全部脚本 bash -n 语法检查" bash -c '
  set -e
  for f in "'"$REPO"'/scripts/"*.sh "'"$REPO"'/scripts/coli-ssd" "'"$REPO"'/tests/"*.sh; do
    bash -n "$f" || exit 1
  done'

# ---------- T2: 装配引擎（本地源码路径） ----------
t_run 2 "build_engine.sh --src 装配引擎到 SSD" \
  "$REPO/scripts/build_engine.sh" --ssd "$SSD" --src "$SRC"

# ---------- T3: PIN 网络路径（真实走一遍 build_engine.sh 的克隆+构建+装配） ----------
t_run 3 "build_engine.sh 网络路径（PIN 克隆→构建→装配，含 tarball 兜底）" bash -c '
  W="$(mktemp -d)"; trap "rm -rf \"$W\"" EXIT
  "'"$REPO"'/scripts/build_engine.sh" --ssd "$W/ssd"
  test -x "$W/ssd/engine/linux-x86_64/glm"
  test -f "$W/ssd/engine/linux-x86_64/PROVENANCE"
  grep -q "$(cat "'"$REPO"'/PIN")" "$W/ssd/engine/linux-x86_64/PROVENANCE"'

# ---------- T4: 夹具模型 ----------
FIXTURE="$BASE/glm_bench_i4"
if [ -d /tmp/glm_bench_i4 ] && [ -f /tmp/glm_bench_i4/.colibri-fixture ]; then
  info "T4: 复用已有夹具 /tmp/glm_bench_i4"
  cp -a /tmp/glm_bench_i4 "$FIXTURE" && t_ok 4 "复用夹具模型" || t_fail 4 "复用夹具模型"
else
  t_run 4 "make_tiny_model.sh 生成夹具（torch/transformers 真实转换路径）" \
    "$HERE/make_tiny_model.sh" --src "$SRC" --out "$FIXTURE"
fi

# ---------- T5: 放入 SSD 并启动推理 ----------
mkdir -p "$SSD/model"
rm -rf "$SSD/model/glm52_i4"; cp -a "$FIXTURE" "$SSD/model/glm52_i4"
t_run 5 "start.sh run 真实推理（路径带空格 + 相对目录无关性）" bash -c '
  cd /   # 故意从无关 cwd 调用
  COLI_MIN_RAM_GB=0 "'"$SSD"'/start.sh" run --ngen 8 "hello" 2>&1 | grep -qE "tok/s|decode"'

# ---------- T6: 只读模式 ----------
t_run 6 "--readonly 在不可写模型目录上不产生状态文件" bash -c '
  M="'"$SSD"'/model/glm52_i4"
  rm -f "$M/.coli_kv"* "$M/.coli_usage" 2>/dev/null
  chmod -R a-w "$M"
  cd /
  COLI_MIN_RAM_GB=0 "'"$SSD"'/start.sh" --readonly run --ngen 4 "hi" >/dev/null 2>&1
  RC=$?
  chmod -R u+w "$M"
  [ $RC -eq 0 ] || { echo "exit=$RC"; exit 1; }
  ls "$M"/.coli_kv "$M"/.coli_usage 2>/dev/null && exit 1
  exit 0'

# ---------- T7: verify 正/负向 ----------
t_run 7 "verify_model.sh 通过夹具（--fixture）" \
  "$REPO/scripts/verify_model.sh" --model "$SSD/model/glm52_i4" --fixture
t_run 8 "verify_model.sh 拒绝空目录（负向）" bash -c '
  E="$(mktemp -d)"; trap "rm -rf \"$E\"" EXIT
  ! "'"$REPO"'/scripts/verify_model.sh" --model "$E" >/dev/null 2>&1'

# ---------- T9: iobench ----------
t_run 9 "iobench_check.sh 实测并输出判定" bash -c '
  "'"$REPO"'/scripts/iobench_check.sh" --ssd "'"$SSD"'" 2>&1 | grep -qE "GB/s|判定"'

# ---------- T10: 缺模型错误提示（负向） ----------
t_run 10 "start.sh 对缺模型给出可操作错误（负向）" bash -c '
  rm -rf "'"$SSD"'/model/glm52_i4"
  ! COLI_MIN_RAM_GB=0 "'"$SSD"'/start.sh" >/dev/null 2>&1'

# ---------- T11: doctor 负向 ----------
t_run 11 "coli-ssd doctor 在半成品 SSD 上非零退出（负向）" bash -c '
  ! "'"$REPO"'/scripts/coli-ssd" doctor --ssd "'"$SSD"'" >/dev/null 2>&1'

# ---------- T12: GUI 检测逻辑（无头） ----------
mkdir -p "$SSD/model"
rm -rf "$SSD/model/glm52_i4"; cp -a "$FIXTURE" "$SSD/model/glm52_i4" 2>/dev/null || true
t_run 12 "GUI 启动器检测逻辑（import 无头 + detect_status 字段正确）" bash -c '
  cd "'"$REPO"'/gui"
  python3 - "'"$SSD"'" <<'"'"'PY'"'"'
import sys
import colibri_ssd as g
root = sys.argv[1]
assert g.find_root(root + "/gui/colibri_ssd.py") == root, "find_root 解析错误"
st = g.detect_status(root)
assert st["engine_ok"], "引擎未检出"
assert st["model"] == "fixture", "模型状态错误: %s" % st["model"]
assert st["mtp"] == "skip"
assert st["platform"].startswith(("linux-", "darwin-")), st["platform"]
assert isinstance(st["ram_gb"], int)
print("detect_status ok")
PY'

# ---------- T13: 浏览器界面冒烟（真实 API + 静态站） ----------
mkdir -p "$SSD/webui"
if [ -f /tmp/colibri/web/dist/index.html ]; then
  rm -rf "$SSD/webui"; cp -a /tmp/colibri/web/dist "$SSD/webui"
else
  echo "<html><body>stub</body></html>" > "$SSD/webui/index.html"
fi
t_run 13 "start.sh ui 冒烟：API /health + /v1/models + Web UI 页面均可访问" bash -c '
  APIP=18231; UIP=18232
  COLI_MIN_RAM_GB=0 python3 "'"$SSD"'/scripts/serve_ui.py" \
    --engine "'"$SSD"'/engine/linux-x86_64" --model "'"$SSD"'/model/glm52_i4" \
    --webui "'"$SSD"'/webui" --api-port $APIP --ui-port $UIP --no-browser \
    --health-timeout 180 >/tmp/e2e_ui.log 2>&1 &
  SVPID=$!
  trap "kill -TERM $SVPID 2>/dev/null; sleep 1; kill -9 $SVPID 2>/dev/null" EXIT
  for i in $(seq 1 180); do
    sleep 1
    H=$(curl -fsS -o /dev/null -w "%{http_code}" http://127.0.0.1:$APIP/health 2>/dev/null || echo 000)
    [ "$H" = 200 ] && break
  done
  [ "$H" = 200 ] || { echo "API /health 未就绪: $H"; tail -5 /tmp/e2e_ui.log; exit 1; }
  sleep 2
  M=$(curl -fsS http://127.0.0.1:$APIP/v1/models 2>/dev/null) || { echo "/v1/models 失败"; exit 1; }
  W=$(curl -fsS http://127.0.0.1:$UIP/ 2>/dev/null) || { echo "Web UI 页面失败"; exit 1; }
  echo "$W" | grep -qi "html" || { echo "Web UI 页面非 HTML"; exit 1; }
  kill -TERM $SVPID 2>/dev/null; sleep 1; kill -9 $SVPID 2>/dev/null
  trap - EXIT
  exit 0'

# ---------- T14: shellcheck 静态检查零告警 ----------
t_run 14 "shellcheck 全部脚本零告警（warning 级）" bash -c '
  SC="${SHELLCHECK:-$(command -v shellcheck || echo /tmp/shellcheck)}"
  [ -x "$SC" ] || { echo "shellcheck 不可用，跳过"; exit 0; }
  "$SC" -S warning "'"$REPO"'/scripts/"*.sh "'"$REPO"'/scripts/coli-ssd" "'"$REPO"'/tests/"*.sh "'"$REPO"'/install.sh"'

# ---------- T15: install.sh 参数与 dry-run ----------
t_run 15 "install.sh --dry-run 正常 + 缺 --ssd 正确报错（负向）" bash -c '
  D="$(mktemp -d)"; trap "rm -rf \"$D\"" EXIT
  "'"$REPO"'/install.sh" --ssd "$D" --skip-download --dry-run >/dev/null 2>&1 || exit 1
  ! "'"$REPO"'/install.sh" --dry-run >/dev/null 2>&1'

# ---------- T16: --help 输出回归（不得混入代码行） ----------
t_run 16 "--help 输出纯净且含用法关键词（start.sh/coli-ssd/install.sh）" bash -c '
  for f in "'"$REPO"'/scripts/start.sh" "'"$REPO"'/scripts/coli-ssd" "'"$REPO"'/install.sh"; do
    OUT=$("$f" --help 2>&1 || true)
    # coli-ssd 无参时也打印用法
    [ "$f" = "'"$REPO"'/scripts/coli-ssd" ] && OUT=$("$f" 2>&1 || true)
    echo "$OUT" | grep -q "set -euo pipefail" && { echo "$f: help 混入代码行"; exit 1; }
    echo "$OUT" | grep -qE "ssd|start" || { echo "$f: help 缺用法内容"; exit 1; }
  done'

# ---------- T17: serve_ui 退出码（BUG-1 回归） ----------
t_run 17 "serve_ui：引擎缺失=干净退出 1；健康检查超时=退出 1（不得为 0）" bash -c '
  S="'"$SSD"'/scripts/serve_ui.py"
  E="'"$SSD"'/engine/linux-x86_64"
  M="'"$SSD"'/model/glm52_i4"
  W="'"$SSD"'/webui"
  # (a) 引擎路径不存在 → 退出 1 且无 Traceback
  OUT=$(python3 "$S" --engine /nonexistent --model "$M" --webui "$W" --no-browser 2>&1); RC=$?
  [ $RC -eq 1 ] || { echo "引擎缺失时退出码 $RC != 1"; exit 1; }
  echo "$OUT" | grep -q Traceback && { echo "引擎缺失时抛裸 traceback"; exit 1; }
  # (b) 真实引擎但健康检查超时 0.2s → 必须退出 1（修复前为 0）
  python3 "$S" --engine "$E" --model "$M" --webui "$W" --api-port 18241 --ui-port 18242 \
    --no-browser --health-timeout 0.2 >/dev/null 2>&1; RC=$?
  # 括号技巧：防止 pkill 的模式匹配到本脚本自身（自杀）
  pkill -f "col[i] serve" 2>/dev/null || true
  [ $RC -eq 1 ] || { echo "健康检查超时时退出码 $RC != 1（BUG-1 回归）"; exit 1; }
  exit 0'

echo >&2
if [ "$FAILT" -eq 0 ]; then
  ok "全部 $PASS 项测试通过"
  exit 0
else
  err "$FAILT 项失败 / $((PASS+FAILT)) 项"
  exit 1
fi
