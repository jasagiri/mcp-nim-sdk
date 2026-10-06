#!/usr/bin/env python3
"""Per-version interop matrix between this SDK (Nim) and the official Python / TypeScript peers.

Usage: run_nim.py [--env DIR] [--out DIR] [--builds V,..] [--versions V,..]
                  [--transports stdio,http,sse] [--directions to-nim,from-nim]
                  [--jobs N] [--no-build] [--list]

Nim is built five times, once per protocol version as the build default
(-d:mcpDefaultProtocolVersion=V). For every build and transport:
  to-nim    an official client pinned to version V (or probing, "auto") -> the Nim server
  from-nim  the Nim client -> an official server whose newest version is V

A row passes only if both independent records agree, as in run_versions.py:
  client side: the JSON line the client prints ("protocolVersion")
  server side: the "VER ..." lines tee_stdio.py / tee_http.py wrote for that run
Each row also states what it expects:
  ok:<v>             must negotiate exactly <v>
  reject             must not succeed (the client may not reach a version the build lacks)
  reject-or-downgrade  must not succeed at a version newer than the build's; failing, or
                     settling on the build's own version, are both correct (peer-specific)
HTTP+SSE (2024-11-05) rows are run in both directions: the Nim server serves it on /sse next to
/mcp, and nim_client takes `sse URL`. Streamable HTTP rows start at 2025-03-26 (2024-11-05
predates it).

--env DIR     environment made by peers/setup.sh (read only); default build/interop
--out DIR     where binaries, logs and results go; default build/interop-nim
Results: a Markdown table (nim_versions.md) and one JSON object per row (nim_versions.jsonl)
in --out. Exit code 1 if any row fails.
"""
import argparse
import json
import os
import socket
import subprocess
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import run_versions as rv

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
VERSIONS = rv.VERSIONS
MODERN = rv.MODERN
# Ports come from the OS, not a fixed range: other jobs on the machine use 18xxx too, and a
# collision makes the logging proxy forward to somebody else's server.
_port_lock = threading.Lock()
_recent_ports: set[int] = set()
ROW_TIMEOUT = 45


def older_or_equal(a: str, b: str) -> bool:
    return a <= b  # ISO dates sort as dates


def build(version: str, bindir: Path) -> None:
    """Compile the three programs with `version` as the build default."""
    out = bindir / version
    out.mkdir(parents=True, exist_ok=True)
    for prog in ("nim_stdio_server", "nim_http_server", "nim_client"):
        cmd = ["nim", "c", "--hints:off", "--warnings:off", f"-d:mcpDefaultProtocolVersion={version}",
               "--path:src", f"--nimcache:{bindir}/nc_{version}_{prog}", f"-o:{out / prog}",
               str(HERE.parent / f"{prog}.nim")]
        done = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)
        if done.returncode != 0:
            raise SystemExit(f"build failed for {prog} @ {version}:\n{done.stdout[-1500:]}{done.stderr[-1500:]}")


# --- the rows ---------------------------------------------------------------

def to_nim_rows(D: str, transport: str) -> list[dict]:
    """Official clients -> the Nim server built with default version D."""
    rows = []

    def add(peer: str, cmd: list, want, fixed_by: str, pin: str):
        if pin == "auto":
            expect = f"ok:{D}"
        elif older_or_equal(pin, D):
            expect = f"ok:{pin}"
        elif pin == MODERN:
            expect = "reject"  # adopts 2026-07-28 without a handshake: nothing to fall back on
        else:
            expect = "reject-or-downgrade"
        rows.append({"direction": "to-nim", "peer": peer, "peer_cmd": cmd, "want": want, "fixed_by": fixed_by,
                     "pin": pin, "expect": expect})

    first = "2025-03-26" if transport == "http" else "2024-11-05"
    for v in VERSIONS:
        if transport == "sse" and v != "2024-11-05":
            continue
        if transport == "http" and v < first:
            continue
        for name, (cmd, want, how) in {**rv.py_clients(v), **rv.ts_clients(v)}.items():
            if transport == "sse" and name.startswith("ts2"):
                continue  # the TS 2.x client package has no HTTP+SSE transport
            add(name, cmd, want, how, v)
    if transport != "sse":
        for name, (cmd, want, how) in {"py2 auto": (rv.PY2 + [str(rv.W / "py/py2_client.py")], "auto", "probe + fallback"),
                                       "ts2 auto": (["node", str(rv.W / "ts/ts2_client.mjs")], "auto", "probe + fallback")}.items():
            add(name, cmd, want, how, "auto")
    return rows


def from_nim_rows(D: str, transport: str) -> list[dict]:
    """The Nim client (built with default version D) -> official servers with a newest version V."""
    rows = []
    first = "2025-03-26" if transport == "http" else "2024-11-05"
    for v in VERSIONS:
        if transport == "sse" and v != "2024-11-05":
            continue
        if transport == "http" and v < first:
            continue
        servers = {**rv.ts_servers(v), **rv.py_servers(v)}
        servers = {k: s for k, s in servers.items() if "no cap" not in k or v == MODERN}
        if transport == "sse":  # only the 1.x SDKs have HTTP+SSE servers
            servers = {k: s for k, s in servers.items() if "native" in k}
        for name, (cmd, sargs) in servers.items():
            cap = MODERN if "no cap" in name else v
            expect = f"ok:{min(D, cap)}"
            row = {"direction": "from-nim", "peer": name, "peer_cmd": cmd, "peer_args": sargs, "pin": cap,
                   "expect": expect}
            if name == "py 1.8.1 native":
                # That release exits on any unknown request, so the 2026-07-28 probe kills it
                # (py2 "auto" fails against it the same way). Cap the client instead of probing.
                row["want"], row["fixed_by"] = cap, "client ceiling (the peer dies on the discover probe)"
            rows.append(row)
    if transport != "sse":
        # a server that only speaks 2026-07-28: older builds must fail against it
        rows.append({"direction": "from-nim", "peer": "ts2 2026-07-28 only",
                     "peer_cmd": ["node", str(rv.W / "ts/ts2_server.mjs")], "peer_args": ["--legacy=reject"],
                     "pin": MODERN, "expect": "ok:" + MODERN if D == MODERN else "reject"})
    return rows


def all_rows(builds, versions, transports, directions) -> list[dict]:
    rows = []
    for D in builds:
        for t in transports:
            if t == "http" and D == "2024-11-05":
                continue  # the build speaks only 2024-11-05, which has no Streamable HTTP
            batch = []
            if "to-nim" in directions:
                batch += to_nim_rows(D, t)
            if "from-nim" in directions:
                batch += from_nim_rows(D, t)
            for r in batch:
                if versions and r["pin"] not in versions and r["pin"] != "auto":
                    continue
                rows.append({"build": D, "transport": t, **r})
    for i, r in enumerate(rows):
        r["id"] = i
    return rows


# --- running one row --------------------------------------------------------

def free_port_pair() -> int:
    """A port P such that P and P + 1 were both free a moment ago (server and proxy)."""
    with _port_lock:
        for _ in range(100):
            with socket.socket() as a:
                a.bind(("127.0.0.1", 0))
                port = a.getsockname()[1]
            if port in _recent_ports or port + 1 in _recent_ports or port >= 65535:
                continue
            with socket.socket() as b:
                try:
                    b.bind(("127.0.0.1", port + 1))
                except OSError:
                    continue
            _recent_ports.update((port, port + 1))
            return port
    raise RuntimeError("no free port pair")


def wait_port(port: int) -> None:
    """Python and Node servers need several seconds to start on a busy machine."""
    for _ in range(300):
        with socket.socket() as s:
            if s.connect_ex(("127.0.0.1", port)) == 0:
                return
        time.sleep(0.1)
    raise RuntimeError(f"port {port} did not open within 30s")


def run_row(row: dict, bindir: Path, logs: Path) -> dict:
    D, transport, rid = row["build"], row["transport"], row["id"]
    nim = lambda prog: str(bindir / D / prog)
    log = logs / f"{rid:04d}_{transport}_{D}_{row['direction']}.log"
    log.unlink(missing_ok=True)
    port = free_port_pair() if transport != "stdio" else 0
    env = {"PATH": os.environ["PATH"], "HOME": os.environ["HOME"]}
    if row.get("want"):
        env["MCP_VERSION"] = row["want"]
    if row["direction"] == "to-nim":
        ccmd = row["peer_cmd"]
        scmd, sargs = [nim("nim_stdio_server" if transport == "stdio" else "nim_http_server")], []
    else:
        ccmd = [nim("nim_client")]
        scmd, sargs = row["peer_cmd"], row["peer_args"]
    procs, timed_out = [], False
    started = time.monotonic()
    try:
        if transport == "stdio":
            target = ["python3", str(rv.W / "py/tee_stdio.py"), str(log)] + scmd + ["stdio"] + sargs
        else:
            err = open(logs / f"{log.stem}.server.err", "w")
            procs.append(subprocess.Popen(scmd + [transport, str(port)] + sargs, stderr=err, stdout=err))
            wait_port(port)
            procs.append(subprocess.Popen(["python3", str(rv.W / "py/tee_http.py"), str(log), str(port + 1),
                                           f"http://127.0.0.1:{port}"]))
            wait_port(port + 1)
            old = any(o in " ".join(scmd) for o in ("py-1.8.1", "py-1.9.4"))  # these mount /mcp/
            target = [f"http://127.0.0.1:{port + 1}/{'sse' if transport == 'sse' else ('mcp/' if old else 'mcp')}"]
        try:
            done = subprocess.run(ccmd + [transport] + target, env=env, capture_output=True, text=True,
                                  timeout=ROW_TIMEOUT)
            lines = [l for l in done.stdout.splitlines() if l.startswith("{")]
            try:
                cjson = json.loads(lines[-1]) if lines else {"ok": False, "error": "no JSON output: " + done.stderr[-200:]}
            except ValueError:
                cjson = {"ok": False, "error": "unparsable output: " + lines[-1][:200]}
            code = done.returncode
        except subprocess.TimeoutExpired:
            timed_out, code = True, -1
            cjson = {"ok": False, "error": f"timed out after {ROW_TIMEOUT}s"}
        time.sleep(0.2)  # let the proxy flush
    finally:
        for p in reversed(procs):
            p.terminate()
            p.wait()
    ver = [l.strip() for l in log.read_text().splitlines() if l.startswith("VER ")] if log.exists() else []
    field = lambda key, via: sorted({l.split()[1].split("=", 1)[1] for l in ver
                                     if l.startswith(f"VER {key}=") and via in l})
    return {
        "client_exit": code, "client": cjson, "timed_out": timed_out,
        "seconds": round(time.monotonic() - started, 1),
        "server_requested_initialize": field("requested", "via=initialize"),
        "server_requested_meta": field("requested", "via=_meta"),
        "server_answered_initialize": field("answered", "via=initialize"),
        "server_answered_discover": field("answered", "via=server/discover"),
        "server_errors": field("error", ""),
        "log": str(log),
    }


def settled_at(r: dict, v: str) -> bool:
    """Both records say the run settled on version v."""
    if not (r["client_exit"] == 0 and r["client"].get("ok") and r["client"].get("protocolVersion") == v):
        return False
    if v == MODERN:  # every request carries the envelope, and no initialize appears
        return r["server_requested_meta"] == [v] and not r["server_requested_initialize"]
    return r["server_answered_initialize"] == [v]


def judge(row: dict, r: dict) -> tuple[bool, str]:
    expect, D = row["expect"], row["build"]
    succeeded = r["client_exit"] == 0 and r["client"].get("ok")
    if r["timed_out"]:
        return False, "timed out"
    if expect.startswith("ok:"):
        v = expect[3:]
        return settled_at(r, v), "" if settled_at(r, v) else f"expected {v}"
    if expect == "reject":
        return (not succeeded), "" if not succeeded else f"succeeded at {r['client'].get('protocolVersion')}"
    # reject-or-downgrade
    if not succeeded:
        return True, "rejected"
    return (settled_at(r, D), f"downgraded to {D}" if settled_at(r, D) else
            f"succeeded at {r['client'].get('protocolVersion')}, the build speaks up to {D}")


def execute(row: dict, bindir: Path, logs: Path) -> dict:
    out = {k: v for k, v in row.items() if k not in ("peer_cmd", "peer_args", "want")}
    try:
        r = run_row(row, bindir, logs)
    except Exception as e:  # the row records the failure
        return {**out, "status": "fail", "note": f"runner error: {type(e).__name__}: {e}"}
    ok, note = judge(row, r)
    got = r["client"].get("protocolVersion") or ("ERR " + str(r["client"].get("error"))[:80])
    return {**out, "status": "pass" if ok else "fail", "note": note, "got": got,
            "seconds": r["seconds"], "server_saw_initialize": r["server_requested_initialize"],
            "server_saw_meta": r["server_requested_meta"],
            "server_answered": r["server_answered_initialize"] or r["server_answered_discover"],
            "log": r["log"]}


def markdown(results: list[dict], elapsed: float) -> str:
    out = ["# Nim ⇔ 公式 SDK の版ごとの相互接続", "",
           f"所要時間 {elapsed:.0f} 秒、{len(results)} 行。", ""]
    counts = {s: sum(1 for r in results if r["status"] == s) for s in ("pass", "fail")}
    out += [f"合格 {counts['pass']} / 不合格 {counts['fail']}", ""]
    for t in sorted({r["transport"] for r in results}):
        for D in VERSIONS:
            sub = [r for r in results if r["transport"] == t and r["build"] == D]
            if not sub:
                continue
            out += [f"## {t} / Nim のビルド {D}", "",
                    "| 結果 | 向き | 相手 | 固定した版 | 期待 | 実際 | 備考 |", "|---|---|---|---|---|---|---|"]
            for r in sub:
                direction = "公式 → Nim" if r["direction"] == "to-nim" else "Nim → 公式"
                mark = {"pass": "合格", "fail": "**不合格**"}[r["status"]]
                out.append(f"| {mark} | {direction} | {r['peer']} | {r['pin']} | {r['expect']} | "
                           f"{r.get('got', '-')} | {r.get('note', '')} |")
            out.append("")
    return "\n".join(out)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--env", default=str(ROOT / "build/interop"))
    ap.add_argument("--out", default=str(ROOT / "build/interop-nim"))
    ap.add_argument("--builds", default=",".join(VERSIONS))
    ap.add_argument("--versions", default="", help="only rows whose peer version / cap is in this list")
    ap.add_argument("--transports", default="stdio,http,sse")
    ap.add_argument("--directions", default="to-nim,from-nim")
    ap.add_argument("--jobs", type=int, default=3)
    ap.add_argument("--no-build", action="store_true")
    ap.add_argument("--list", action="store_true", help="print the rows and exit")
    a = ap.parse_args()

    rv.W = Path(a.env).resolve()
    rv.PY2 = [str(rv.W / "py2/.venv/bin/python")]  # computed at import time from the old W
    out = Path(a.out).resolve()
    logs = out / "logs"
    logs.mkdir(parents=True, exist_ok=True)
    builds = [b for b in a.builds.split(",") if b]
    for b in builds:
        if b not in VERSIONS:
            raise SystemExit(f"unknown build version {b}")
    rows = all_rows(builds, [v for v in a.versions.split(",") if v], a.transports.split(","),
                    a.directions.split(","))
    if a.list:
        for r in rows:
            print(r["id"], r["build"], r["transport"], r["direction"], r["peer"], r["pin"], r["expect"])
        return 0

    started = time.monotonic()
    if not a.no_build:
        for b in builds:
            print(f"building Nim programs for default version {b} ...", flush=True)
            build(b, out)
    results = []
    with ThreadPoolExecutor(max_workers=a.jobs) as pool:
        for res in pool.map(lambda r: execute(r, out, logs), rows):
            results.append(res)
            print(f"{res['status'].upper():13} | {res['transport']:5} | build {res['build']} | {res['direction']:8} | "
                  f"{res['peer']:22} | pin {res['pin']} | expect {res['expect']} | got {res.get('got', '-')} "
                  f"{res.get('note', '')}", flush=True)
    elapsed = time.monotonic() - started
    (out / "nim_versions.jsonl").write_text("".join(json.dumps(r, ensure_ascii=False) + "\n" for r in results))
    (out / "nim_versions.md").write_text(markdown(results, elapsed))
    failed = [r for r in results if r["status"] == "fail"]
    print(f"\n{len(failed)} failing row(s) of {len(results)}; {elapsed:.0f}s; table in {out / 'nim_versions.md'}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
