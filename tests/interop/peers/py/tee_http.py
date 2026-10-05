"""Logging reverse proxy for an HTTP MCP server, Streamable HTTP or HTTP+SSE (stdlib only).

Usage: tee_http.py LOGFILE LISTEN_PORT UPSTREAM_URL
  e.g. tee_http.py logs/http.log 18600 http://127.0.0.1:18601
Point the client at http://127.0.0.1:LISTEN_PORT/mcp (or /sse). LOGFILE gets:
  - "VER ..." lines (see wirelog.py) as messages pass, plus
    "VER header=<v> method=<m>" for each request carrying MCP-Protocol-Version
  - one JSON line per finished HTTP exchange: method, path, MCP-relevant
    headers, request body, status, response body (SSE included).
"""
import http.client
import json
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit

from wirelog import version_lines

log_path, listen_port, upstream = sys.argv[1], int(sys.argv[2]), urlsplit(sys.argv[3])
lock = threading.Lock()
HOP = {"connection", "keep-alive", "transfer-encoding", "content-length", "host"}


def write(lines: list[str]) -> None:
    if lines:
        with lock, open(log_path, "a") as f:
            f.write("".join(line + "\n" for line in lines))


class Proxy(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def relay(self) -> None:
        body = self.rfile.read(int(self.headers.get("content-length") or 0))
        if self.headers.get("mcp-protocol-version"):
            method = self.headers.get("mcp-method") or self.command
            write([f"VER header={self.headers['mcp-protocol-version']} method={method}"])
        write(version_lines(body))
        conn = http.client.HTTPConnection(upstream.hostname, upstream.port)
        headers = {k: v for k, v in self.headers.items() if k.lower() not in HOP}
        conn.request(self.command, self.path, body=body or None, headers=headers)
        resp = conn.getresponse()
        self.send_response(resp.status)
        for k, v in resp.getheaders():
            if k.lower() not in HOP:
                self.send_header(k, v)
        self.send_header("Connection", "close")
        self.end_headers()
        is_sse = "text/event-stream" in (resp.getheader("content-type") or "")
        chunks, pending = [], b""
        try:
            while chunk := resp.read1(65536):
                chunks.append(chunk)
                if is_sse:  # report versions as events arrive; the stream may never end
                    *lines, pending = (pending + chunk).split(b"\n")
                    for line in lines:
                        if line.startswith(b"data:"):
                            write(version_lines(line[5:]))
                self.wfile.write(chunk)
                self.wfile.flush()
        finally:
            conn.close()
            self.close_connection = True
            text = b"".join(chunks).decode("utf-8", "replace")
            entry = {
                "method": self.command,
                "path": self.path,
                "req_headers": {k.lower(): v for k, v in self.headers.items()
                                if k.lower().startswith("mcp-") or k.lower() in ("accept", "content-type")},
                "req_body": body.decode("utf-8", "replace"),
                "status": resp.status,
                "resp_headers": {k.lower(): v for k, v in resp.getheaders()
                                 if k.lower().startswith("mcp-") or k.lower() == "content-type"},
                "resp_body": text,
            }
            write(([] if is_sse else version_lines(text)) + [json.dumps(entry)])

    do_GET = do_POST = do_DELETE = relay

    def log_message(self, *args) -> None:
        pass


ThreadingHTTPServer(("127.0.0.1", listen_port), Proxy).serve_forever()
