"""本地预览官网。

    python3 site/serve.py     →  http://127.0.0.1:4321

处理无扩展名路径（/privacy → privacy/index.html），行为对齐
deploy/nginx/perch.conf 里的 try_files，避免本地能开、线上 404。
"""
import functools
import http.server
import os
import socketserver

ROOT = os.path.dirname(os.path.abspath(__file__))
PORT = 4321


class Handler(http.server.SimpleHTTPRequestHandler):
    def translate_path(self, path):
        local = super().translate_path(path)
        if os.path.isdir(local):
            return local
        if not os.path.exists(local):
            for candidate in (os.path.join(local, "index.html"), local + ".html"):
                if os.path.isfile(candidate):
                    return candidate
        return local


socketserver.TCPServer.allow_reuse_address = True
handler = functools.partial(Handler, directory=ROOT)
with socketserver.TCPServer(("127.0.0.1", PORT), handler) as httpd:
    print(f"serving {ROOT} at http://127.0.0.1:{PORT}", flush=True)
    httpd.serve_forever()
