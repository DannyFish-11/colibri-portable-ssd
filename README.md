# colibri-portable-ssd

**把 744B 参数的 GLM-5.2 装进一块外置 SSD：插上电脑一条命令就跑，用完拔掉就走。**

基于上游 [JustVugg/colibri](https://github.com/JustVugg/colibri)（Apache-2.0）—— 一个把 GLM-5.2（744B MoE，int4 约 370GB）的专家权重留在硬盘上、按需流式读入的纯 C 推理引擎。本仓库把它打包成**即插即用的移动 SSD 方案**：引擎、模型、启动器、自检工具全部驻留在 SSD 上，模型路径完全相对化，插到任何满足条件的电脑上 `./start.sh` 即可。

> 为什么可行：colibri 的模型分片本来就是**只读打开、按需 pread**（`c/st.h`），模型路径完全由运行时环境变量 `COLI_MODEL` 指定、容器内无任何硬编码绝对路径。本方案不是改造引擎，而是把它的设计前提外置化。

---

## 快速开始

### 一、制作这块 SSD（一次性，需要网络和 gcc）

```bash
git clone https://github.com/DannyFish-11/colibri-portable-ssd
cd colibri-portable-ssd

# 1. 构建引擎并装配 SSD 目录树（linux-x86_64 / darwin-arm64 自动识别）
scripts/coli-ssd build --ssd /mnt/myssd

# 2. 下载模型（约 370GB，断点续传，中断重跑同一命令即可）
scripts/coli-ssd download --ssd /mnt/myssd

# 3. 总检：引擎 + 模型完整性 + MTP 头 + 实测盘速
scripts/coli-ssd doctor --ssd /mnt/myssd
```

### 二、日常使用（插到任何电脑）

```bash
/mnt/myssd/start.sh                # 交互聊天
/mnt/myssd/start.sh run "提示词"    # 单次生成
/mnt/myssd/start.sh serve          # OpenAI 兼容 API
/mnt/myssd/start.sh --readonly     # 纯只读模式：全程不向 SSD 写任何状态
```

Windows 11：双击 `start.bat`（需预装 Python 3.10+）。用完正常退出，再安全弹出。

---

## 硬前提（不满足不要折腾）

| 条件 | 底线 | 说明 |
|---|---|---|
| 宿主机可用内存 | **≥16GB，建议 ≥25GB** | SSD 只搬存储，不搬内存。稠密权重常驻 ~9.9GB，聊天峰值 RSS ~20GB |
| 宿主机 CPU | x86_64 需 **AVX2**；或 Apple Silicon | 引擎便携构建的底线指令集 |
| SSD | **≥500GB NVMe**（模型 ~370GB） | 机械盘/网络盘不可用 |
| 接口 | **USB 3.2 Gen2 (10Gbps) 起步，建议 USB4/雷电** | 见下方速度对照 |
| 文件系统 | **NTFS（Win 主力）或 ext4（Linux 主力）** | FAT32 单文件 4GB 上限直接出局；exFAT 会丢 O_DIRECT/io_uring 优化 |
| 宿主机软件 | Python 3.10+ | 引擎本体是 C，CLI 是 Python |

## 接口速度对照（上游 README + 社区实测）

| 链路 | 随机读量级 | 冷态体验 |
|---|---|---|
| USB 3.0 (5Gbps) | ~0.45 GB/s | 比作者基线慢一倍，不推荐 |
| **USB 3.2 Gen2 (10Gbps)** | **~1 GB/s** | **= 作者开发机基线：冷态 0.05–0.1 tok/s（第一句按分钟等），热缓存后明显改善** |
| USB4 / 雷电硬盘盒 | ~2.5–3.5 GB/s | 冷态明显更好 |
| 原生 PCIe4/5 NVMe | 3.5–8.8+ GB/s | 0.3–1+ tok/s，社区实测最高 2+ tok/s（大内存 pin 热专家） |

关键事实：作者本人的开发机就是 ~1 GB/s 随机读跑通的。**一块像样的 10Gbps 硬盘盒就达到了已验证基线。** 每块盘插到新机器上，先跑一次 `scripts/iobench_check.sh --ssd <挂载点>` 拿你自己的真实数字。

## SSD 目录树

```
<SSD>/
├── start.sh / start.bat        # 即插即用启动器（自定位路径，与 cwd 无关）
├── README-FIRST.txt
├── model/glm52_i4/             # 370GB int4 模型（只读分片 + config + tokenizer）
│   ├── out-00001.safetensors … #   只读，引擎 pread
│   ├── out-mtp-*.safetensors   #   int8 MTP 头（推测解码 ~2x 杠杆，verify 会校验）
│   ├── .coli_kv                #   会话 KV 缓存（~182KB/token，crash-safe；--readonly 不写）
│   └── .coli_usage             #   学习缓存：记录你的专家路由习惯，越用越快，跟盘走
├── engine/
│   ├── linux-x86_64/           # 上游锁定 commit 构建（含 PROVENANCE 溯源文件）
│   ├── darwin-arm64/
│   └── windows-x86_64/
├── bin/iobench                 # 盘速实测工具（复现引擎的 19MB 并行随机读）
└── scripts/                    # lib.sh / verify_model.sh / iobench_check.sh
```

## 仓库命令

| 命令 | 作用 |
|---|---|
| `coli-ssd build --ssd <路径>` | 克隆上游锁定 commit（PIN 文件）→ 构建 → 装配 SSD（含 tarball 网络兜底） |
| `coli-ssd download --ssd <路径>` | HF 下载 370GB 模型，断点续传，下完自动校验 |
| `coli-ssd verify --ssd <路径>` | 校验：分片头、总体积、MTP int8 三件套尺寸 |
| `coli-ssd bench --ssd <路径>` | iobench 实测盘速并按上游基线给出判定 |
| `coli-ssd doctor --ssd <路径>` | 以上全部，一键总检 |

## 拔插安全（"拔掉就行"的准确含义）

- **模型分片全程只读**（引擎 `O_RDONLY` 打开），任何时候都不会被写坏。
- 运行中的写入只有两个 KB 级状态文件（`.coli_kv` / `.coli_usage`），append-only、crash-safe。
- **正常姿势：退出聊天 → 安全弹出。** 运行中硬拔 = 进程死掉，但模型数据无损。
- `./start.sh --readonly`（`KVSAVE=0`）让 SSD 接近纯只读负载，硬拔也无伤大雅。
- 详见 [docs/SAFETY.md](docs/SAFETY.md)。

## 文档

- [docs/HARDWARE.md](docs/HARDWARE.md) — 硬盘盒/接口选购、散热、速度对照
- [docs/FILESYSTEM.md](docs/FILESYSTEM.md) — NTFS/ext4/exFAT 抉择与格式化命令
- [docs/SAFETY.md](docs/SAFETY.md) — 拔插安全、只读模式、杀毒软件排除
- [docs/TESTING.md](docs/TESTING.md) — 本仓库发布前实际跑过的测试与结果
- [README_EN.md](README_EN.md) — English version

## 诚实的边界

- 这是**"能跑 744B 的工程样机"**，不是"随身聊天助手"。冷态 0.05–0.1 tok/s 意味着第一句按分钟等；热缓存、MTP、热专家 pin 之后才会进入可用区间。适合：长推理任务、离线/隐私场景、研究 MoE 路由与缓存。不适合：即问即答、演示。
- 模型本体 370GB **不在本仓库**，由 `download` 命令从 Hugging Face 拉取。
- 上游引擎锁定在 [`PIN`](PIN) 指定的 commit；升级 = 更新 PIN 重跑 `build`。

## 测试

```bash
tests/e2e_tiny.sh                 # 端到端套件（~170MB 夹具模型，真实转换+真实推理路径）
```

11 项测试覆盖：脚本语法、双路径装配（本地源码 / 网络 PIN 克隆）、带空格路径的真实推理、只读模式零写入、模型校验正/负向、盘速判定、错误提示质量。结果见 [docs/TESTING.md](docs/TESTING.md)。

## 许可

本仓库的脚本与文档：**Apache-2.0**（与上游一致）。上游引擎的许可与溯源文件随引擎装配到 `engine/<platform>/LICENSE.upstream` 与 `PROVENANCE`。GLM-5.2 模型权重遵循其 [Hugging Face 模型卡](https://huggingface.co/zai-org/GLM-5.2)的许可。
