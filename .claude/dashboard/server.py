"""Serve the dashboard page and its snapshot on 127.0.0.1 only (spec TT-783).

Usage: python3 server.py <port> <index.html> <snapshot.json>
Two fixed paths, no request-derived file access; foreign Host headers get 403 (DNS rebinding).
Python 3.9 stdlib only.
"""
import socket
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT, INDEX, SNAPSHOT = int(sys.argv[1]), sys.argv[2], sys.argv[3]
ALLOWED_HOSTS = {f"127.0.0.1:{PORT}", f"localhost:{PORT}"}
HTML = "text/html; charset=utf-8"
ROUTES = {"/": (INDEX, HTML), "/index.html": (INDEX, HTML),
          "/snapshot.json": (SNAPSHOT, "application/json")}


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.headers.get("Host", "") not in ALLOWED_HOSTS:
            return self.send_error(403)
        route = ROUTES.get(self.path.split("?", 1)[0])
        if route is None:
            return self.send_error(404)
        try:
            with open(route[0], "rb") as f:
                body = f.read()
        except OSError:
            return self.send_error(503, "snapshot not ready")
        self.send_response(200)
        self.send_header("Content-Type", route[1])
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


IN_USE = f"port {PORT} in use — set TEAM_DASH_PORT"
# SO_REUSEADDR lets a loopback bind succeed beside a wildcard listener on macOS; probe first.
try:
    socket.create_connection(("127.0.0.1", PORT), timeout=0.5).close()
    sys.exit(IN_USE)
except OSError:
    pass
try:
    server = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
except OSError:
    sys.exit(IN_USE)
try:
    server.serve_forever()
except KeyboardInterrupt:
    server.server_close()
