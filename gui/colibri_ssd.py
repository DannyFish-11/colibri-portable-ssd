#!/usr/bin/env python3
"""colibri-ssd GUI 启动器 — 零依赖（纯标准库 tkinter），三平台双击可用。

放在 SSD 的 gui/ 目录。插上电脑后：
    Windows:  双击 colibri_ssd.py（或 gui/启动器.bat）
    Linux:    python3 gui/colibri_ssd.py
    macOS:    python3 gui/colibri_ssd.py

检测逻辑（detect_status）与界面分离，可无头单测。
没有 tkinter 或没有显示环境时，退化为打印 start.sh 用法，绝不崩溃。
"""
import os
import platform
import shutil
import subprocess
import sys

# ---------------------------------------------------------------- 检测逻辑（无 GUI 依赖）

MTP_INT8 = ["3527131672", "5366238584", "1065950496"]
MTP_INT4 = ["1765523544", "2686077736", "536747200"]


def find_root(argv0):
    """gui/colibri_ssd.py -> SSD 根目录；仓库内 scripts 同级同理。"""
    here = os.path.dirname(os.path.abspath(argv0))
    parent = os.path.dirname(here)
    if os.path.basename(here) == "gui":
        return parent
    return parent if os.path.isdir(os.path.join(parent, "gui")) else here


def detect_platform():
    sysname, machine = platform.system(), platform.machine().lower()
    osname = {"Linux": "linux", "Darwin": "darwin"}.get(sysname, "windows")
    arch = "arm64" if machine in ("arm64", "aarch64") else "x86_64"
    return f"{osname}-{arch}"


def has_avx2():
    if platform.machine().lower() not in ("x86_64", "amd64"):
        return True  # arm64 无此概念
    try:
        if platform.system() == "Linux":
            return "avx2" in open("/proc/cpuinfo").read()
        if platform.system() == "Darwin":
            out = subprocess.run(["sysctl", "-a"], capture_output=True, text=True, timeout=5).stdout
            return "AVX2" in out
        # Windows: 近 10 年 x86 CPU 基本都有 AVX2，交给引擎自己报错
        return True
    except Exception:
        return True


def avail_ram_gb():
    try:
        if platform.system() == "Linux":
            with open("/proc/meminfo") as f:
                for line in f:
                    if line.startswith("MemAvailable"):
                        return int(line.split()[1]) // 1048576
        if platform.system() == "Darwin":
            out = subprocess.run(["sysctl", "-n", "hw.memsize"], capture_output=True, text=True, timeout=5)
            return int(out.stdout.strip()) // 1073741824
        if platform.system() == "Windows":
            import ctypes
            class MS(ctypes.Structure):
                _fields_ = [("dwLength", ctypes.c_ulong), ("dwMemoryLoad", ctypes.c_ulong),
                            ("ullTotalPhys", ctypes.c_ulonglong), ("ullAvailPhys", ctypes.c_ulonglong),
                            ("ullTotalPageFile", ctypes.c_ulonglong), ("ullAvailPageFile", ctypes.c_ulonglong),
                            ("ullTotalVirtual", ctypes.c_ulonglong), ("ullAvailVirtual", ctypes.c_ulonglong),
                            ("ullAvailExtendedVirtual", ctypes.c_ulonglong)]
            ms = MS(); ms.dwLength = ctypes.sizeof(MS)
            ctypes.windll.kernel32.GlobalMemoryStatusEx(ctypes.byref(ms))
            return ms.ullAvailPhys // 1073741824
    except Exception:
        pass
    return 0


def model_status(model_dir):
    """返回 (状态码, 描述)。状态码: ok / incomplete / missing / fixture"""
    if not os.path.isdir(model_dir):
        return "missing", "模型未下载"
    for f in ("config.json", "tokenizer.json"):
        if not os.path.isfile(os.path.join(model_dir, f)):
            return "incomplete", f"缺 {f}（下载不完整）"
    import glob
    shards = glob.glob(os.path.join(model_dir, "out-*.safetensors"))
    if not shards:
        return "incomplete", "缺 out-*.safetensors 分片（下载不完整）"
    if os.path.isfile(os.path.join(model_dir, ".colibri-fixture")):
        return "fixture", "测试夹具模型（非真实模型）"
    return "ok", f"就绪（{len(shards)} 个分片）"


def mtp_status(model_dir):
    import glob
    files = sorted(glob.glob(os.path.join(model_dir, "out-mtp-*.safetensors")))
    if not files:
        return "missing", "无 MTP 头（推测解码不可用，能跑但慢）"
    sizes = [str(os.path.getsize(f)) for f in files]
    if sizes == MTP_INT8:
        return "ok", "int8 MTP 正确（推测解码 ~2x）"
    if sizes == MTP_INT4:
        return "bad", "MTP 是 int4 版！接受率 0%，需替换三个 out-mtp-* 文件"
    return "bad", "MTP 尺寸异常，文件可能损坏"


def detect_status(root):
    plat = detect_platform()
    model_dir = os.environ.get("COLI_MODEL_DIR", os.path.join(root, "model", "glm52_i4"))
    ms, md = model_status(model_dir)
    if ms == "fixture":
        mtp, mtpd = "skip", "夹具跳过"
    elif ms == "missing":
        mtp, mtpd = "skip", "—"
    else:
        mtp, mtpd = mtp_status(model_dir)
    return {
        "platform": plat,
        "engine": os.path.join(root, "engine", plat),
        "engine_ok": os.path.isfile(os.path.join(root, "engine", plat, "coli")),
        "webui": os.path.join(root, "webui"),
        "webui_ok": os.path.isfile(os.path.join(root, "webui", "index.html")),
        "model_dir": model_dir,
        "model": ms, "model_desc": md,
        "mtp": mtp, "mtp_desc": mtpd,
        "ram_gb": avail_ram_gb(),
        "avx2": has_avx2(),
    }


# ---------------------------------------------------------------- GUI（仅 main 内使用）

def launch_terminal_cmd(root, args):
    """返回在系统终端里运行 start.sh/start.bat 的命令（按平台）。找不到返回 None。"""
    if platform.system() == "Windows":
        bat = os.path.join(root, "start.bat")
        return ["cmd", "/c", "start", "cmd", "/k", bat] + args
    sh = os.path.join(root, "start.sh")
    cmdline = " ".join([f'"{sh}"'] + [f'"{a}"' for a in args]) + "; echo; echo 按回车关闭; read"
    if platform.system() == "Darwin":
        # open 会把额外参数当文件打开，必须用 AppleScript 传完整命令行
        return ["osascript", "-e",
                f'tell application "Terminal" to do script "{cmdline.replace(chr(34), chr(92)+chr(34))}"']
    for term, flag in (("x-terminal-emulator", "-e"), ("gnome-terminal", "--"),
                       ("konsole", "-e"), ("xfce4-terminal", "-e"), ("xterm", "-e")):
        if shutil.which(term):
            return [term, flag, "bash", "-c", cmdline]
    return None


def bash_cmd(root, script, *args):
    """构造 bash 脚本调用；Windows 无 bash 时返回 None（由调用方友好提示）。"""
    if platform.system() == "Windows" and not shutil.which("bash"):
        return None
    return ["bash", os.path.join(root, "scripts", script)] + list(args)


def main():
    root = find_root(sys.argv[0])
    try:
        import tkinter as tk
        from tkinter import scrolledtext
    except ImportError:
        print("此机 Python 无 tkinter。改用命令行: ./start.sh（Linux/macOS）或 start.bat（Windows）")
        return 1

    st = detect_status(root)

    app = tk.Tk()
    app.title("colibri-portable-ssd · 即插即用 AI SSD")
    app.geometry("680x560")

    tk.Label(app, text="colibri · GLM-5.2 (744B) 便携 SSD", font=("", 15, "bold")).pack(pady=(12, 2))
    tk.Label(app, text=f"根目录: {root}", fg="#666").pack()

    frm = tk.Frame(app); frm.pack(fill="x", padx=16, pady=8)
    rows = [
        ("平台", st["platform"], True),
        ("引擎", "就绪" if st["engine_ok"] else "未装配（先跑 coli-ssd build）", st["engine_ok"]),
        ("模型", st["model_desc"], st["model"] in ("ok", "fixture")),
        ("MTP 推测解码", st["mtp_desc"], st["mtp"] in ("ok", "skip")),
        ("可用内存", f"~{st['ram_gb']} GB（建议 ≥25）", st["ram_gb"] >= 16),
        ("AVX2", "支持" if st["avx2"] else "不支持！引擎无法运行", st["avx2"]),
        ("浏览器界面", "已构建" if st["webui_ok"] else "未构建（可选，跑 build_webui.sh）", True),
    ]
    for i, (k, v, good) in enumerate(rows):
        tk.Label(frm, text=k, anchor="w", width=14).grid(row=i, column=0, sticky="w")
        tk.Label(frm, text=v, anchor="w", fg=("#2a7" if good else "#c33")).grid(row=i, column=1, sticky="w")

    logw = scrolledtext.ScrolledText(app, height=12, state="disabled", font=("monospace", 9))
    logw.pack(fill="both", expand=True, padx=16, pady=8)

    def log(msg):
        logw.configure(state="normal"); logw.insert("end", msg + "\n")
        logw.see("end"); logw.configure(state="disabled")

    def run_bg(cmd, note=""):
        import threading
        def work():
            logw.after(0, log, "$ " + " ".join(str(c) for c in cmd))
            try:
                p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
                for line in p.stdout:
                    logw.after(0, log, line.rstrip())
                p.wait()
                logw.after(0, log, f"[退出码 {p.returncode}] {note}")
            except Exception as e:
                logw.after(0, log, f"[错误] {e}")
        threading.Thread(target=work, daemon=True).start()

    def do_chat(readonly=False):
        args = (["--readonly"] if readonly else []) + ["chat"]
        cmd = launch_terminal_cmd(root, args)
        if cmd is None:
            log("找不到可用终端模拟器；请手动运行 ./start.sh chat")
        else:
            subprocess.Popen(cmd)

    def do_ui():
        run_bg([sys.executable, os.path.join(root, "scripts", "serve_ui.py"),
                "--engine", st["engine"], "--model", st["model_dir"], "--webui", st["webui"]])

    def do_bench():
        cmd = bash_cmd(root, "iobench_check.sh", "--ssd", root)
        if cmd is None:
            log("此功能需要 bash（Windows 请安装 Git Bash 或用 WSL）；也可手动跑 scripts/iobench_check.sh")
            return
        run_bg(cmd)

    def do_verify():
        cmd = bash_cmd(root, "verify_model.sh", "--model", st["model_dir"])
        if cmd is None:
            log("此功能需要 bash（Windows 请安装 Git Bash 或用 WSL）；也可手动跑 scripts/verify_model.sh")
            return
        run_bg(cmd)

    btns = tk.Frame(app); btns.pack(pady=4)
    tk.Button(btns, text="开始聊天", width=12, command=lambda: do_chat(False)).grid(row=0, column=0, padx=4)
    tk.Button(btns, text="只读模式聊天", width=12, command=lambda: do_chat(True)).grid(row=0, column=1, padx=4)
    tk.Button(btns, text="浏览器界面", width=12, command=do_ui).grid(row=0, column=2, padx=4)
    tk.Button(btns, text="检测盘速", width=12, command=do_bench).grid(row=0, column=3, padx=4)
    tk.Button(btns, text="校验模型", width=12, command=do_verify).grid(row=0, column=4, padx=4)

    tk.Label(app, text="用完在聊天窗口正常退出，再安全弹出 SSD。模型分片全程只读，不会写坏。",
             fg="#666").pack(pady=(0, 10))
    app.mainloop()
    return 0


if __name__ == "__main__":
    sys.exit(main())
