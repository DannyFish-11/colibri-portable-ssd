# 发布前实测记录

测试时间：2026-07-17（UTC）。测试机：Linux x86_64 沙箱（gcc 12.2，2 核，4GB RAM）。
上游引擎：colibri @ `72d3d37`（2026-07-16，见仓库根 `PIN`）。

## 测试套件：`tests/e2e_tiny.sh` — 11/11 通过

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

未能在本环境验证（需要你的硬件）：
- 真实 370GB 模型（本沙箱磁盘/RAM 不足）——但下载器是 huggingface_hub 官方 `snapshot_download`（断点续传为其内建行为），校验器已按上游公开的分片头格式与 MTP 尺寸表实现
- Windows `start.bat` 的运行时行为（静态审查通过；逻辑与 bash 版同构）
- macOS / Apple Silicon 构建（脚本按 darwin-arm64 设计，未实测）
- 真实 USB4/雷电硬盘盒的速度与热表现

在你的硬件上完成首次 `coli-ssd doctor` 后，欢迎把 iobench 数字和体验发 issue——上游项目也明确在收集真实硬件数据点。
