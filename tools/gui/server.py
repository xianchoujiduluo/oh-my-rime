#!/usr/bin/env python3
# encoding: utf-8
"""
薄荷输入法图形设置 —— 本地服务入口

为什么需要它：macOS 鼠须管从上游就没有设置界面（源码里连 .xib 都没有），
皮肤、方案、词典三件事在 Windows 小狼毫上是图形化的，在 Mac 上只能改 YAML。
本服务把这三件事变成网页点选操作。

设计要点:
  * 只用标准库，不装任何第三方包。装了 git 的 macOS 必有 /usr/bin/python3。
  * 浏览器不能直接写文件，所以本服务是「桥」：网页管界面，本服务管落盘。
  * 只监听 127.0.0.1，端口随机 + 一次性 token，避免被同机其它程序盲调。
  * 写配置一律走「合并 + 备份」，绝不整份覆盖用户已有的 .custom.yaml。
"""
import json
import os
import sys
import threading
import webbrowser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from rime_actions import RimeApp          # noqa: E402
from rime_paths import detect_dir         # noqa: E402

INDEX = HERE / "index.html"
TOKEN = os.urandom(16).hex()              # 每次启动都是新的


class Handler(BaseHTTPRequestHandler):
    app = None
    server_version = "mint-gui"

    def log_message(self, *args):
        pass                              # 静音，免得刷屏

    def _send(self, code, body, ctype="application/json; charset=utf-8"):
        data = body if isinstance(body, bytes) else body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def _json(self, obj, code=200):
        self._send(code, json.dumps(obj, ensure_ascii=False))

    def _authorized(self):
        return self.headers.get("X-Mint-Token") == TOKEN

    def do_GET(self):
        path = self.path.split("?")[0]
        if path in ("/", "/index.html"):
            html = INDEX.read_text(encoding="utf-8").replace("__TOKEN__", TOKEN)
            return self._send(200, html, "text/html; charset=utf-8")
        if not self._authorized():
            return self._json({"error": "unauthorized"}, 403)
        try:
            if path == "/api/state":
                return self._json({
                    "user_dir": str(self.app.user_dir),
                    "front": self.app.front,
                    "skin": self.app.skin_state(),
                    "schema": self.app.schema_state(),
                    "dict": self.app.dict_state(),
                })
            return self._json({"error": "not found"}, 404)
        except Exception as exc:          # 让前端看到具体原因而不是白屏
            return self._json({"error": "%s: %s" % (type(exc).__name__, exc)}, 500)

    def do_POST(self):
        if not self._authorized():
            return self._json({"error": "unauthorized"}, 403)
        length = int(self.headers.get("Content-Length") or 0)
        try:
            payload = json.loads(self.rfile.read(length) or b"{}")
        except Exception:
            return self._json({"error": "bad json"}, 400)

        path = self.path.split("?")[0]
        try:
            if path == "/api/skin":
                r = self.app.skin_apply(payload.get("light"), payload.get("dark"))
            elif path == "/api/schema":
                r = self.app.schema_apply(payload.get("ids") or [])
            elif path == "/api/dict":
                r = self.app.dict_action(payload.get("action"), payload.get("name"))
            elif path == "/api/deploy":
                r = self.app.redeploy()
            else:
                return self._json({"error": "not found"}, 404)
            return self._json({"ok": True, "result": r})
        except Exception as exc:
            return self._json({"ok": False, "error": "%s" % exc}, 400)


def main():
    import argparse

    ap = argparse.ArgumentParser(description="薄荷输入法图形设置")
    ap.add_argument("--target", help="Rime 用户目录（默认自动探测）")
    ap.add_argument("--port", type=int, default=0, help="监听端口（0=随机）")
    ap.add_argument("--no-browser", action="store_true", help="不自动打开浏览器")
    args = ap.parse_args()

    user_dir = Path(args.target) if args.target else detect_dir()
    if not user_dir.is_dir():
        print("错误: Rime 用户目录不存在: %s" % user_dir, file=sys.stderr)
        print("提示: 用 --target 指定，例如 --target ~/Library/Rime", file=sys.stderr)
        return 1

    app = RimeApp(user_dir)
    Handler.app = app
    httpd = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    url = "http://127.0.0.1:%d/" % httpd.server_address[1]

    print("薄荷输入法图形设置")
    print("  用户目录: %s" % user_dir)
    print("  前端配置: %s" % app.custom)
    print("  地址:     %s" % url)
    print("  按 Ctrl+C 退出")
    print()

    if not args.no_browser:
        threading.Timer(0.4, lambda: webbrowser.open(url)).start()

    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\n已退出。")
    finally:
        httpd.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
