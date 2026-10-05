"""Echo server on the Python SDK 2.x (mcp>=2). Usage: py2_server.py stdio | http PORT | sse PORT

stdio / http are dual-era: the client's opening request decides between the
initialize handshake (2024-11-05..2025-11-25) and the 2026-07-28 envelope.
sse is the 2024-11-05 HTTP+SSE transport (GET /sse, POST /messages/).
The newest version this server speaks is fixed by the SDK (no public cap); to
get a lower ceiling run py1_server.py on an older SDK (see run_versions.py).
"""
import sys

from mcp.server.mcpserver import MCPServer

mcp = MCPServer("interop-echo-py2", version="0.0.1", log_level="WARNING")


@mcp.tool()
def echo(text: str) -> str:
    """Echo back the given text."""
    return text


if __name__ == "__main__":
    if sys.argv[1] == "stdio":
        mcp.run("stdio")
    else:
        transport = "sse" if sys.argv[1] == "sse" else "streamable-http"
        mcp.run(transport, host="127.0.0.1", port=int(sys.argv[2]))
