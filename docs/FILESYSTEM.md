# 文件系统抉择

模型分片单文件约 5GB，总量约 370GB。上游明确要求**本地 ext4/NTFS，禁止网络盘/9p 挂载**。

## 结论先行

| 你的主力机器 | 选这个 | 原因 |
|---|---|---|
| 主要是 Windows | **NTFS** | 原生支持；Linux 内核 5.15+ 的 ntfs3 驱动读写都可用 |
| 主要是 Linux | **ext4** | 原生最快，O_DIRECT/io_uring 全部生效 |
| Windows + Linux 都要插 | **NTFS** | 妥协解：Linux 用 ntfs3 挂载；macOS 原生只能读 |
| 三端含 macOS | NTFS + Mac 上装 macFuse/ntfs-3g，或接受 mac 端只读体验 | 没有完美解 |
| exFAT | **不推荐** | 跨平台最省事，但丢掉 O_DIRECT/io_uring 优化，Linux 下走 FUSE 性能差，且无日志、意外拔掉更易脏 |
| FAT32 | **出局** | 单文件 4GB 上限，5GB 分片放不下 |
| APFS | 出局 | 只有 macOS 认 |

## 格式化命令

### Windows（图形或命令行）

```bat
REM 管理员 cmd；X: 换成你的盘符。快速格式化即可。
format X: /FS:NTFS /Q /A:64K /V:COLIBRI
```

64K 簇对大文件顺序读略好；默认 4K 也完全可用。

### Linux

```bash
# 确认设备名（别格错盘！）
lsblk
# ext4：大文件友好，关掉保留块（数据盘不需要 5% 保留）
sudo mkfs.ext4 -L COLIBRI -m 0 -O large_file /dev/sdX1
# 或 NTFS（跨平台方案）：
sudo mkfs.ntfs -Q -L COLIBRI /dev/sdX1
```

### macOS

```bash
diskutil list          # 确认设备
diskutil eraseDisk ExFAT COLIBRI /dev/diskN   # 万不得已才 exFAT
# 正经方案：盘格 NTFS（在 Win/Linux 上格），mac 端用只读挂载 + 本地缓存状态文件
```

## 挂载注意事项

- **Linux noexec**：个别发行版的安全策略会把可移动盘挂成 noexec，引擎二进制将拒绝执行。`start.sh` 启动前会自动检测并给出修复命令（`mount -o remount,exec`）。
- **Linux ntfs3 vs ntfs-3g**：内核 ≥5.15 优先用内核态 ntfs3（`mount -t ntfs3`），比 FUSE 的 ntfs-3g 快得多。
- **macOS 免密挂载外置盘**：即插即用无特殊要求；若 Gatekeeper 拦截引擎，`xattr -dr com.apple.quarantine /Volumes/COLIBRI`。
