"""Client on the Python SDK 1.x. Usage: py1_client.py stdio CMD [ARGS...] | http URL | sse URL

Without MCP_VERSION it offers the installed SDK's LATEST_PROTOCOL_VERSION, so
the requested version is chosen by the virtualenv:
  mcp 1.8.1 -> 2024-11-05, 1.9.4 -> 2025-03-26, 1.22.0 -> 2025-06-18, 1.30.0 -> 2025-11-25
MCP_VERSION overrides the offer (no public API; a module global is replaced).
Prints one JSON line (protocolVersion = negotiated version); exit code 0 on success.
"""
import asyncio
import json
import os
import sys
from importlib.metadata import version

import mcp.types as types
from mcp import ClientSession, StdioServerParameters

IMPL = f"python-mcp-{version('mcp')}"


def open_transport(kind: str, target: list[str]):
    if kind == "stdio":
        from mcp.client.stdio import stdio_client

        return stdio_client(StdioServerParameters(command=target[0], args=target[1:]))
    if kind == "sse":
        from mcp.client.sse import sse_client

        return sse_client(target[0])
    from mcp.client.streamable_http import streamablehttp_client

    return streamablehttp_client(target[0])


async def main() -> dict:
    kind, target = sys.argv[1], sys.argv[2:]
    want = os.environ.get("MCP_VERSION")
    if want:
        # No public knob: ClientSession.initialize() reads types.LATEST_PROTOCOL_VERSION.
        types.LATEST_PROTOCOL_VERSION = want
    async with open_transport(kind, target) as streams, ClientSession(streams[0], streams[1]) as session:
        init = await session.initialize()
        tools = await session.list_tools()
        result = await session.call_tool("echo", {"text": "hello"})
        return {
            "ok": not result.isError and result.content[0].text == "hello",
            "impl": IMPL,
            "requested": want or types.LATEST_PROTOCOL_VERSION,
            "protocolVersion": init.protocolVersion,
            "tools": [t.name for t in tools.tools],
            "result": result.content[0].text,
        }


if __name__ == "__main__":
    try:
        out = asyncio.run(main())
    except BaseException as e:  # report every failure as JSON, then fail
        while isinstance(e, BaseExceptionGroup) and len(e.exceptions) == 1:
            e = e.exceptions[0]  # anyio wraps the real failure in a one-element group
        out = {"ok": False, "impl": IMPL, "error": f"{type(e).__name__}: {e}"}
    print(json.dumps(out))
    sys.exit(0 if out["ok"] else 1)
