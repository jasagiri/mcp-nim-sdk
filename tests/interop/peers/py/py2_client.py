"""Client on the Python SDK 2.x. Usage: py2_client.py stdio CMD [ARGS...] | http URL | sse URL

MCP_VERSION selects what is requested:
  unset / "auto"      -> mode="auto" (probe server/discover, fall back to initialize)
  "2026-07-28"        -> mode="2026-07-28" (adopt directly, no probe)       [public API]
  "2025-11-25"        -> mode="legacy" (the SDK's handshake default)        [public API]
  an older version    -> mode="legacy" with the offered version overridden  [no public API]
Prints one JSON line (protocolVersion = negotiated version); exit code 0 on success.
"""
import asyncio
import json
import os
import sys

import mcp.client.session as session_module
from mcp import Client, StdioServerParameters
from mcp_types.version import HANDSHAKE_PROTOCOL_VERSIONS


async def main() -> dict:
    kind, target = sys.argv[1], sys.argv[2:]
    want = os.environ.get("MCP_VERSION") or "auto"
    mode = want
    if want in HANDSHAKE_PROTOCOL_VERSIONS:
        # No public knob: ClientSession.initialize() offers this module global.
        session_module.LATEST_HANDSHAKE_VERSION = want
        mode = "legacy"
    if kind == "stdio":
        server = StdioServerParameters(command=target[0], args=target[1:])
    elif kind == "sse":
        from mcp.client.sse import sse_client

        server = sse_client(target[0])
    else:
        server = target[0]
    async with Client(server, mode=mode) as client:
        tools = await client.list_tools()
        result = await client.call_tool("echo", {"text": "hello"})
        return {
            "ok": not result.is_error and result.content[0].text == "hello",
            "impl": "python-mcp-2.x",
            "requested": want,
            "protocolVersion": client.protocol_version,
            "tools": [t.name for t in tools.tools],
            "result": result.content[0].text,
        }


if __name__ == "__main__":
    try:
        out = asyncio.run(main())
    except BaseException as e:  # report every failure as JSON, then fail
        while isinstance(e, BaseExceptionGroup) and len(e.exceptions) == 1:
            e = e.exceptions[0]  # anyio wraps the real failure in a one-element group
        out = {"ok": False, "impl": "python-mcp-2.x", "error": f"{type(e).__name__}: {e}"}
    print(json.dumps(out))
    sys.exit(0 if out["ok"] else 1)
