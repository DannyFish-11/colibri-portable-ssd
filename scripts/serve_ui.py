#!/usr/bin/env python3
"""serve_ui.py — 一键拉起 colibri 浏览器界面

做的事（全部 stdlib，无第三方依赖）：
  1. 启动 `coli serve`（OpenAI 兼容 API，默认 127.0.0.1:8000）
  2. 等待 /health 就绪
  3. 用 http.server 托管 SSD 上预构建的 Web UI（默认 127.0.0.1:7860）
  4. 自动打开浏览器；Ctrl-C 时两个进程一起干净退出

用法:
  serve_ui.py --engine <引擎目录> --model <模型目录> --webui <webui目录>
              [--api-port 8000] [--ui-port 7860] [--no-browser] [--readonly]
"""
import argparse
import http.server
import os
import signal
import socketserver
import subprocess
import sys
import threading
import time
import urllib.request
import webbrowser


def log(msg):
    print(f"[ui] {msg}", file=sys.stderr, flush=True)


def wait_health(port, timeout, proc):
    deadline = time.time() + timeout
    url = f"http://127.0.0.1:{port}/health"
    while time.time() < deadline:
        if proc.poll() is not None:
            return False
        try:
            with urllib.request.urlopen(url, timeout=2) as r:
                if r.status == 200:
                    return True
        except Exception:
            pass
        time.sleep(1)
    return False


class QuietHandler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *a):
        pass


class UIServer(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


def main():
    p = argparse.ArgumentParser(description="colibri Web UI 一键启动")
    p.add_argument("--engine", required=True)
    p.add_argument("--model", required=True)
    p.add_argument("--webui", required=True)
    p.add_argument("--api-port", type=int, default=8000)
    p.add_argument("--ui-port", type=int, default=7860)
    p.add_argument("--no-browser", action="store_true")
    p.add_argument("--readonly", action="store_true")
    p.add_argument("--health-timeout", type=float, default=600)
    a = p.parse_args()

    if not os.path.isfile(os.path.join(a.webui, "index.html")):
        log(f"Web UI 未构建: {a.webui} 缺 index.html")
        log("在制作机上运行: scripts/build_webui.sh --ssd <SSD挂载点>")
        return 1

    env = dict(os.environ)
    env["COLI_MODEL"] = a.model
    if a.readonly:
        env["KVSAVE"] = "0"

    serve_cmd = [
        sys.executable, os.path.join(a.engine, "coli"), "serve",
        "--model", a.model,
        "--host", "127.0.0.1", "--port", str(a.api_port),
        "--cors-origin", f"http://127.0.0.1:{a.ui_port}",
    ]
    log(f"启动 API: {' '.join(serve_cmd)}")
    try:
        api = subprocess.Popen(serve_cmd, env=env)
    except OSError as e:
        log(f"无法启动引擎: {e}（引擎未装配？先跑 coli-ssd build）")
        return 1

    def cleanup(code=0, *_):
        try:
            api.terminate()
        except Exception:
            pass
        try:
            api.wait(timeout=10)
        except Exception:
            try:
                api.kill()
            except Exception:
                pass
        sys.exit(code)

    signal.signal(signal.SIGINT, cleanup)
    signal.signal(signal.SIGTERM, cleanup)

    log(f"等待模型加载（首次 ~30s 起，大模型更久，超时 {a.health_timeout:.0f}s）……")
    if not wait_health(a.api_port, a.health_timeout, api):
        log("API 未就绪或进程已退出")
        cleanup(1)
    log(f"API 就绪: http://127.0.0.1:{a.api_port}/v1")

    import functools
    handler = functools.partial(QuietHandler, directory=a.webui)
    with UIServer(("127.0.0.1", a.ui_port), handler) as httpd:
        url = f"http://127.0.0.1:{a.ui_port}/"
        log(f"Web UI: {url}  （在界面里把 endpoint 填为 http://127.0.0.1:{a.api_port}/v1，点 Probe server）")
        if not a.no_browser:
            threading.Timer(0.5, lambda: webbrowser.open(url)).start()
        try:
            httpd.serve_forever()
        except KeyboardInterrupt:
            pass
    cleanup(0)
    return 0


if __name__ == "__main__":
    sys.exit(main())
