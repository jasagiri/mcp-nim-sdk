"""Shared by tee_stdio.py / tee_http.py: turn one JSON-RPC message into "VER ..." lines.

VER requested=<v> via=initialize            client sent initialize with that protocolVersion
VER requested=<v> via=_meta method=<m>      client sent a 2026-07-28 style per-request envelope
VER answered=<v> via=initialize             server's InitializeResult.protocolVersion
VER answered=<v,v> via=server/discover      server's DiscoverResult.supportedVersions
VER error=<code> message=<text>             any JSON-RPC error response
"""
import json

PV_KEY = "io.modelcontextprotocol/protocolVersion"


def version_lines(raw: str | bytes) -> list[str]:
    try:
        parsed = json.loads(raw)
    except ValueError:
        return []
    out = []
    for msg in parsed if isinstance(parsed, list) else [parsed]:
        if not isinstance(msg, dict):
            continue
        params = msg.get("params") if isinstance(msg.get("params"), dict) else {}
        meta = params.get("_meta") if isinstance(params.get("_meta"), dict) else {}
        result = msg.get("result") if isinstance(msg.get("result"), dict) else {}
        if msg.get("method") == "initialize":
            out.append(f"VER requested={params.get('protocolVersion')} via=initialize")
        elif PV_KEY in meta:
            out.append(f"VER requested={meta[PV_KEY]} via=_meta method={msg.get('method')}")
        if "protocolVersion" in result:
            out.append(f"VER answered={result['protocolVersion']} via=initialize")
        if "supportedVersions" in result:
            out.append(f"VER answered={','.join(result['supportedVersions'])} via=server/discover")
        if isinstance(msg.get("error"), dict):
            out.append(f"VER error={msg['error'].get('code')} message={msg['error'].get('message')}")
    return out
