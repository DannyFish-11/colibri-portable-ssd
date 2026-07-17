# 发布前实测记录

测试时间：2026-07-17（UTC）。测试机：Linux x86_64 沙箱（gcc 12.2，2 核，4GB RAM，node 20）。
上游引擎：colibri @ `72d3d37`（2026-07-16，见仓库根 `PIN`）。

## 第三轮：深度 code review 排查（2026-07-17）— 8 个 bug 修复，17/17 通过

逐文件人工 review 发现并已修复：

| # | 文件 | Bug | 后果 | 修复 |
|---|---|---|---|---|
| 1 | serve_ui.py | 健康检查失败时 `cleanup()` 固定 `exit(0)` | **失败被伪装成成功**，脚本判错失效 | `cleanup(code)` 参数化；新增 T17 回归 |
| 2 | start.sh | `--help` sed 范围多一行 | help 末尾混入 `set -euo pipefail` | `2,15p`→`2,13p`；新增 T16 回归 |
| 3 | scripts/coli-ssd | 同上 | 同上 | `2,16p`→`2,14p`，并补 `--help` 支持 |
| 4 | install.sh | 同上 | 同上 | `2,12p`→`2,10p` |
| 5 | download_model.sh | `df -k` 长设备名折行 | 可用空间解析错位 → 误判空间 | `df -kP` + 数字守卫 |
| 6 | gui/colibri_ssd.py | macOS `open` 把参数当文件打开 | macOS 聊天按钮失效 | 改 `osascript do script` |
| 7 | gui/colibri_ssd.py | Windows 无 bash 时测速/校验按钮报错丑陋 | 体验差 | `bash_cmd()` 检测 + 友好提示 |
| 8 | serve_ui.py / lib.sh | 引擎缺失抛裸 traceback；`avail_ram_gb` 失败时空值比较崩溃 | 健壮性 | try/except 干净报错；`have="${have:-0}"` |

测试套件自身也修了 1 个 bug：T17 的 `pkill -f "coli serve"` 会匹配测试脚本自身命令行导致自杀（空日志 FAIL）→ 改用 `col[i]` 括号技巧。

新增回归测试：T16（三个入口脚本 `--help` 输出纯净）、T17（serve_ui 引擎缺失/健康超时退出码均为 1）。

## v2 易用性套件（2026-07-17 第二轮）— 15/15 通过

新增"足够简单易用"的四件套全部实测：

| # | 测试 | 结果 | 说明 |
|---|---|---|---|
| T12 | GUI 启动器逻辑 | ✅ | 无头 import + `detect_status` 全字段断言（引擎/模型夹具/平台/内存） |
| T13 | `start.sh ui` 冒烟 | ✅ | 真实拉起 `coli serve` + 静态站：`/health` 200、`/v1/models` 正常、Web UI 页面可访问 |
| T14 | shellcheck 零告警 | ✅ | v0.10.0，warning 级，覆盖全部 10 个脚本 |
| T15 | `install.sh` | ✅ | `--dry-run` 正常输出计划；缺 `--ssd` 正确非零退出（负向） |

上游 Web UI 本身也过了完整验证：`npm ci` → `npm test`（上游自带测试套件）→ `npm run build` → `dist/` 静态产物，全部一次通过。

## v1 基础套件（第一轮）— 11/11 通过

| # | 测试 | 结果 | 说明 |
|---|---|---|---|
| T1 | 全部脚本 `bash -n` 语法检查 | ✅ | 9 个脚本/启动器 |
| T2 | `build_engine.sh --src` 本地源码装配 | ✅ | 引擎布局原地可运行 |
| T3 | `build_engine.sh` 网络路径：git fetch PIN commit（含 codeload tarball 兜底）→ 构建 → 装配 → PROVENANCE 校验 | ✅ | 真实网络全走通 |
| T4 | `make_tiny_model.sh`：FP8 夹具 → 真实 `convert_fp8_to_int4.py` 转换 → tokenizer 合成 | ✅ | ~167MB int4 容器，结构与真实 370GB 同构 |
| T5 | `start.sh run` 真实推理：**SSD 路径含空格 + 从无关 cwd 调用** | ✅ | 正常生成并输出 tok/s 统计 |
| T6 | `--readonly`：模型目录 `chmod a-w` 后推理成功，且**零状态文件产生**（无 `.coli_kv`/`.coli_usage`） | ✅ | 纯只读模式成立 |
| T7 | `verify_model.sh` 通过合法夹具 | ✅ | safetensors 头逐分片解析 |
| T8 | `verify_model.sh` 拒绝空目录（负向） | ✅ | 非零退出 + 可操作错误信息 |
| T9 | `iobench_check.sh` 实测并输出判定 | ✅ | 找到 SSD 上 bin/iobench，正常解析与分级 |
| T10 | `start.sh` 对缺模型给出可操作错误（负向） | ✅ | 指明 download 命令 |
| T11 | `coli-ssd doctor` 在半成品 SSD 上非零退出（负向） | ✅ | 报告缺项并给出修复顺序 |

## 引擎端到端验证（T4+T5 的含金量）

不是脚本空转——走的是**真实引擎路径**：上游官方夹具生成器产出与真实 FP8 检查点同布局的权重 → 上游官方转换器产出 int4 容器 → 引擎加载 → 分词 → 专家流式加载（8 专家/层）→ 生成。实测输出：`expert hit rate 100%`、`experts loaded/token: 40.0 (per-layer 7.99)`，证明专家路由与磁盘流读路径完整工作。

## 盘速实测（本沙箱，仅佐证 iobench 与判定逻辑）

| 模式 | 结果 | 解读 |
|---|---|---|
| buffered（19MB×64，8 线程） | 3.38 GB/s | 夹具分片小，多为页缓存命中——上游警告过的假象 |
| O_DIRECT | 0.15 GB/s | 沙箱虚拟盘的真实水平 → 判定逻辑正确输出 "slow" 档 |

**这正是每个用户必须在自己硬件上跑一次 `iobench_check.sh` 的原因**：buffered 数字会撒谎，O_DIRECT 才是引擎冷态面对的真实物理。

## 已测试 vs 未测试（诚实边界）

已在本机验证：
- Linux x86_64 下的完整制作→装配→启动→推理→只读→校验→测速闭环
- 路径含空格、符号链接、cwd 无关性、noexec 检测逻辑、内存门槛逻辑
- 网络路径双通道（git / codeload tarball）获取锁定 commit
- 浏览器界面全链路（API /health + /v1/models + 静态站页面）
- shellcheck v0.10.0 静态检查零告警
- `--help` 输出纯净度、serve_ui 失败路径退出码（T16/T17 回归）

未能在本环境验证（需要你的硬件）：
- 真实 370GB 模型（本沙箱磁盘/RAM 不足）——但下载器是 huggingface_hub 官方 `snapshot_download`（断点续传为其内建行为），校验器已按上游公开的分片头格式与 MTP 尺寸表实现
- Windows `start.bat` 的运行时行为（静态审查通过；逻辑与 bash 版同构）
- macOS / Apple Silicon 构建与 osascript 终端拉起（按 Apple 官方机制实现，未实测）
- 真实 USB4/雷电硬盘盒的速度与热表现
- tkinter GUI 的窗口渲染（逻辑已做无头测试；窗口行为请在真机上过目一眼）

在你的硬件上完成首次 `coli-ssd doctor` 后，欢迎把 iobench 数字和体验发 issue——上游项目也明确在收集真实硬件数据点。
