"""Echo server on the Python SDK 1.x (mcp<2). Usage: py1_server.py stdio | http PORT | sse PORT

Handshake era only. The newest version it speaks is the installed SDK's
LATEST_PROTOCOL_VERSION, so the ceiling is chosen by the virtualenv:
  mcp 1.8.1 -> 2024-11-05, 1.9.4 -> 2025-03-26, 1.22.0 -> 2025-06-18, 1.30.0 -> 2025-11-25
sse is the 2024-11-05 HTTP+SSE transport (GET /sse, POST /messages/).
"""
import sys

from mcp.server.fastmcp import FastMCP

port = int(sys.argv[2]) if len(sys.argv) > 2 else 8000
mcp = FastMCP("interop-echo-py1", host="127.0.0.1", port=port, log_level="WARNING")


@mcp.tool()
def echo(text: str) -> str:
    """Echo back the given text."""
    return text


if __name__ == "__main__":
    mcp.run({"stdio": "stdio", "sse": "sse"}.get(sys.argv[1], "streamable-http"))
