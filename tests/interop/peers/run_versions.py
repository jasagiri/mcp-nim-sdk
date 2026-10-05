#!/usr/bin/env python3
"""Per-version interop check between the Python and TypeScript peers (stdlib only).

Usage: run_versions.py [stdio] [http] [sse]      (default: all three)

For each protocol version V and each cross-language client/server pair it runs
the client, then decides from two independent records:
  client side: the JSON line the client prints ("protocolVersion")
  server side: the "VER ..." lines tee_stdio.py / tee_http.py wrote for that run
A row passes only if both say the negotiated version is the expected one.
Results: a table on stdout and one JSON object per row in logs/versions.jsonl.
"""
import json
import shutil
import socket
import subprocess
import sys
import time
from pathlib import Path

W = Path(__file__).resolve().parent
LOGS = W / "logs" / "versions"
VERSIONS = ["2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25", "2026-07-28"]
MODERN = "2026-07-28"
# SDK release whose newest protocol version is V (verified from its LATEST_PROTOCOL_VERSION).
PY_NATIVE = {"2024-11-05": "old/py-1.8.1", "2025-03-26": "old/py-1.9.4", "2025-06-18": "old/py-1.22.0", "2025-11-25": "py1"}
TS_NATIVE = {"2024-11-05": "old/ts-1.10.2", "2025-03-26": "old/ts-1.12.3", "2025-06-18": "old/ts-1.23.1", "2025-11-25": "ts"}
PY2 = [str(W / "py2/.venv/bin/python")]


def py1(v: str, script: str) -> list[str]:
    return [str(W / PY_NATIVE[v] / ".venv/bin/python"), str(W / "py" / script)]


def ts1(v: str, script: str) -> list[str]:
    return ["node", str(W / TS_NATIVE[v] / script)]


# name -> (command, MCP_VERSION or None, how the version is fixed)
def py_clients(v: str) -> dict:
    out = {"py2 pin": (PY2 + [str(W / "py/py2_client.py")], v,
                       "public mode=" if v in (MODERN, "2025-11-25") else "module global (non-public)")}
    if v != MODERN:
        out[f"py {PY_NATIVE[v].split('-')[-1] if '-' in PY_NATIVE[v] else '1.30.0'} native"] = (py1(v, "py1_client.py"), None, "SDK release")
    return out


def ts_clients(v: str) -> dict:
    out = {"ts2 pin": (["node", str(W / "ts/ts2_client.mjs")], v, "public ClientOptions")}
    if v != MODERN:
        out[f"ts {TS_NATIVE[v].split('-')[-1] if '-' in TS_NATIVE[v] else '1.32.1'} native"] = (ts1(v, "ts1_client.mjs"), None, "SDK release")
    return out


# name -> (command without the mode argument, extra argv after it)
def ts_servers(v: str) -> dict:
    out = {"ts2 dual (no cap)": (["node", str(W / "ts/ts2_server.mjs")], [])}
    if v != MODERN:
        out[f"ts2 --max={v}"] = (["node", str(W / "ts/ts2_server.mjs")], [f"--max={v}"])
        out[f"ts {TS_NATIVE[v].split('-')[-1] if '-' in TS_NATIVE[v] else '1.32.1'} native"] = (ts1(v, "ts1_server.mjs"), [])
    return out


def py_servers(v: str) -> dict:
    out = {"py2 dual (no cap)": (PY2 + [str(W / "py/py2_server.py")], [])}
    if v != MODERN:
        out[f"py {PY_NATIVE[v].split('-')[-1] if '-' in PY_NATIVE[v] else '1.30.0'} native"] = (py1(v, "py1_server.py"), [])
    return out


def wait_port(port: int) -> None:
    for _ in range(80):
        with socket.socket() as s:
            if s.connect_ex(("127.0.0.1", port)) == 0:
                return
        time.sleep(0.1)
    raise RuntimeError(f"port {port} did not open")


def run(transport: str, client: tuple, server: tuple, tag: str, port: int) -> dict:
    ccmd, want, _ = client
    scmd, sargs = server
    log = LOGS / f"{tag}.log"
    log.unlink(missing_ok=True)
    env = {"PATH": __import__("os").environ["PATH"], "HOME": __import__("os").environ["HOME"]}
    if want:
        env["MCP_VERSION"] = want
    procs = []
    try:
        if transport == "stdio":
            target = ["python3", str(W / "py/tee_stdio.py"), str(log)] + scmd + ["stdio"] + sargs
        else:
            err = open(LOGS / f"{tag}.server.err", "w")
            procs.append(subprocess.Popen(scmd + [transport, str(port)] + sargs, stderr=err, stdout=err))
            wait_port(port)
            procs.append(subprocess.Popen(["python3", str(W / "py/tee_http.py"), str(log), str(port + 1), f"http://127.0.0.1:{port}"]))
            wait_port(port + 1)
            # mcp 1.8.x / 1.9.x mount Streamable HTTP at /mcp/ and answer /mcp with a redirect
            # to the upstream port, which would bypass the logging proxy.
            mcp_path = "mcp/" if any(old in " ".join(scmd) for old in ("py-1.8.1", "py-1.9.4")) else "mcp"
            target = [f"http://127.0.0.1:{port + 1}/{'sse' if transport == 'sse' else mcp_path}"]
        kind = "stdio" if transport == "stdio" else transport
        done = subprocess.run(ccmd + [kind] + target, env=env, capture_output=True, text=True, timeout=90)
        lines = [l for l in done.stdout.splitlines() if l.startswith("{")]
        cjson = json.loads(lines[-1]) if lines else {"ok": False, "error": "no JSON output: " + done.stderr[-200:]}
        time.sleep(0.2)  # let the proxy flush
    finally:
        for p in reversed(procs):
            p.terminate()
            p.wait()
    ver = [l.strip() for l in log.read_text().splitlines() if l.startswith("VER ")] if log.exists() else []
    field = lambda key, via: sorted({l.split()[1].split("=", 1)[1] for l in ver if l.startswith(f"VER {key}=") and via in l})
    return {
        "client_exit": done.returncode,
        "client": cjson,
        "server_requested_initialize": field("requested", "via=initialize"),
        "server_requested_meta": field("requested", "via=_meta"),
        "server_answered_initialize": field("answered", "via=initialize"),
        "server_answered_discover": field("answered", "via=server/discover"),
        "server_header": field("header", ""),
        "server_errors": field("error", ""),
        "log": str(log.relative_to(W)),
    }


def verdict(v: str, r: dict) -> bool:
    if not (r["client_exit"] == 0 and r["client"].get("ok") and r["client"].get("protocolVersion") == v):
        return False
    if v == MODERN:  # every request must carry the envelope, and no initialize may appear
        return r["server_requested_meta"] == [v] and not r["server_requested_initialize"]
    return r["server_answered_initialize"] == [v]


def main() -> int:
    transports = sys.argv[1:] or ["stdio", "http", "sse"]
    LOGS.mkdir(parents=True, exist_ok=True)
    for t in transports:
        for old in LOGS.glob(f"{t}_*"):
            old.unlink()
    results = W / "logs/versions.jsonl"
    kept = [l for l in results.read_text().splitlines() if json.loads(l)["transport"] not in transports] if results.exists() else []
    for d in TS_NATIVE.values():
        if d != "ts":
            for f in ("ts1_server.mjs", "ts1_client.mjs"):
                shutil.copy(W / "ts" / f, W / d / f)
    rows, port, failed = [], 18700, 0
    out = open(results, "w")
    out.write("".join(l + "\n" for l in kept))
    for transport in transports:
        for v in VERSIONS:
            if transport == "sse" and v != "2024-11-05":
                continue  # HTTP+SSE is the 2024-11-05 transport
            # Note: Streamable HTTP did not exist in 2024-11-05; the SDKs still negotiate that version over it.
            pairs = []
            auto_py = {"py2 auto": (PY2 + [str(W / "py/py2_client.py")], "auto", "probe + fallback")}
            auto_ts = {"ts2 auto": (["node", str(W / "ts/ts2_client.mjs")], "auto", "probe + fallback")}
            tss, pys = ts_servers(v), py_servers(v)
            if transport == "sse":  # the TS 2.x server package has no HTTP+SSE transport
                tss = {k: s for k, s in tss.items() if k.startswith("ts 1.")}
                tss["ts 1.32.1 (no cap)"] = (ts1("2025-11-25", "ts1_server.mjs"), [])
            for cn, c in py_clients(v).items():
                pairs += [(cn, c, sn, s) for sn, s in tss.items()]
            for cn, c in ts_clients(v).items():
                pairs += [(cn, c, sn, s) for sn, s in pys.items()]
            # server-driven downgrade: a newest-first client meets a server whose ceiling is V
            # Not run over sse: the probe is a 2026-era request on a 2024-era transport, and
            # "ts2 auto -> py 1.8.1 sse" fails (the old server never answers the probe; the
            # client reports "Version negotiation probe timed out after 60000ms").
            if transport != "sse":
                pairs += [(cn, c, sn, s) for cn, c in auto_py.items() for sn, s in tss.items() if "no cap" not in sn or v == MODERN]
                pairs += [(cn, c, sn, s) for cn, c in auto_ts.items() for sn, s in pys.items() if "no cap" not in sn or v == MODERN]
            for i, (cn, c, sn, s) in enumerate(pairs):
                port += 2
                tag = f"{transport}_{v}_{i:02d}"
                try:
                    r = run(transport, c, s, tag, port)
                except Exception as e:  # keep going; the row records the failure
                    r = {"client_exit": -1, "client": {"ok": False, "error": f"{type(e).__name__}: {e}"},
                         "server_requested_initialize": [], "server_requested_meta": [], "server_answered_initialize": [],
                         "server_answered_discover": [], "server_header": [], "server_errors": [], "log": ""}
                ok = verdict(v, r)
                failed += not ok
                row = {"transport": transport, "version": v, "client": cn, "client_fix": c[2], "server": sn, "pass": ok, **r}
                out.write(json.dumps(row) + "\n")
                out.flush()
                saw = "init:" + ",".join(r["server_requested_initialize"]) if r["server_requested_initialize"] else ""
                saw += (" " if saw else "") + ("meta:" + ",".join(r["server_requested_meta"]) if r["server_requested_meta"] else "")
                ans = ",".join(r["server_answered_initialize"]) or ("discover:" + ",".join(r["server_answered_discover"]) if r["server_answered_discover"] else "-")
                got = r["client"].get("protocolVersion") or ("ERR " + str(r["client"].get("error"))[:70])
                print(f"{'PASS' if ok else 'FAIL'} | {transport:5} | {v} | {cn:16} -> {sn:20} | client={got} | server saw {saw or '-'} | answered {ans}", flush=True)
    print(f"\n{failed} failing row(s)")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
