#!/usr/bin/env python3
"""Run the official conformance suite (@modelcontextprotocol/conformance) against the Nim programs.

Usage: run_conformance.py [--env DIR] [--out DIR] [--builds V,..] [--roles server,client] [--no-build]

For every build (a Nim build whose default protocol version is V) it runs, with the
spec version V (and, for the 2026-07-28 build, also 2025-11-25, which it speaks too),
  server  nim_conformance_server on 127.0.0.1:PORT, `conformance server --suite all --spec-version V`
  client  nim_conformance_client, `conformance client --suite all --spec-version V`
and writes one JSON object per scenario (conformance.jsonl) and a Markdown table
(conformance.md) into --out. Exit code 1 if any scenario fails: the failures are the
list of what the SDK still lacks, so a non-zero exit is the normal state until it is done.

A scenario's status is the worst of its checks: fail > warn > skipped > pass. INFO checks are
the suite's log of the traffic and do not count; a scenario that has nothing but INFO checks
is "info".
"unsupported" is a client scenario the Nim client program declines to act out
(exit code 2 and "scenario not supported" on stderr), because the SDK has no such client feature.

--env DIR   environment made by peers/setup.sh (read only); default build/interop
--out DIR   where binaries and results go; default build/interop-nim
Default builds are the versions with a Streamable HTTP transport (2025-03-26 and later):
the suite speaks HTTP only.
"""
import argparse
import json
import re
import socket
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
ANSI = re.compile(r"\x1b\[[0-9;]*m")


def free_port() -> int:
    """A port the OS has just confirmed free (other jobs on the machine use fixed ranges)."""
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def wait_port(port: int) -> None:
    for _ in range(300):
        with socket.socket() as s:
            if s.connect_ex(("127.0.0.1", port)) == 0:
                return
        time.sleep(0.1)
    raise RuntimeError(f"port {port} did not open within 30s")


def build(version: str, out: Path, prog: str) -> Path:
    target = out / version / prog
    target.parent.mkdir(parents=True, exist_ok=True)
    cmd = ["nim", "c", "--hints:off", "--warnings:off", f"-d:mcpDefaultProtocolVersion={version}",
           "--path:src", f"--nimcache:{out}/nc_{version}_{prog}", f"-o:{target}", str(HERE.parent / f"{prog}.nim")]
    done = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)
    if done.returncode != 0:
        raise SystemExit(f"build failed for {prog} @ {version}:\n{done.stdout[-1500:]}{done.stderr[-1500:]}")
    return target


def summarize(version: str, spec: str, role: str, resdir: Path) -> list[dict]:
    rows = []
    for checks_file in sorted(resdir.rglob("checks.json")):  # auth scenarios sit in a subdirectory
        d = checks_file.parent
        scenario = re.sub(r"-\d{4}-\d\d-\d\dT[\d-]+Z$", "", str(d.relative_to(resdir)))
        scenario = scenario.removeprefix("server-") if role == "server" else scenario
        checks = json.loads(checks_file.read_text())
        stderr = (d / "stderr.txt").read_text() if (d / "stderr.txt").exists() else ""
        status = "pass"
        order = ["pass", "skipped", "warn", "fail"]
        bad = []
        judged = [c for c in checks if c["status"] != "INFO"]
        for c in judged:
            s = {"SUCCESS": "pass", "FAILURE": "fail", "WARNING": "warn", "INFO": "info", "SKIPPED": "skipped"}.get(
                c["status"], "fail")
            if order.index(s) > order.index(status):
                status = s
            if s in ("fail", "warn"):
                msg = c.get("errorMessage") or c.get("description") or ""
                msg = re.split(r"\s*Async traceback", msg)[0]
                bad.append({"check": c["id"], "status": s, "message": msg[:300].replace("\n", " ")})
        if not judged:
            status = "info"
        if role == "client" and "scenario not supported by this client" in stderr:
            status = "unsupported"
        rows.append({"build": version, "spec": spec, "role": role, "scenario": scenario, "status": status,
                     "passed": sum(c["status"] == "SUCCESS" for c in checks),
                     "failed": sum(c["status"] == "FAILURE" for c in checks), "problems": bad})
    return rows


def markdown(results: list[dict], elapsed: float) -> str:
    out = ["# 公式の適合性テストの結果 (Nim)", "", f"所要時間 {elapsed:.0f} 秒。", ""]
    for role in ("server", "client"):
        for v, spec in sorted({(r["build"], r["spec"]) for r in results}, reverse=True):
            sub = [r for r in results if r["role"] == role and r["build"] == v and r["spec"] == spec]
            if not sub:
                continue
            tally = {s: sum(1 for r in sub if r["status"] == s) for s in ("pass", "warn", "fail", "unsupported", "skipped", "info")}
            out += [f"## {role} / Nim のビルド {v} / 仕様の版 {spec}", "",
                    "合格 {pass} / 警告 {warn} / 不合格 {fail} / クライアントが未対応 {unsupported} / 実行されず {skipped} / 記録のみ {info}".format(**tally),
                    "", "| シナリオ | 結果 | 成功 | 失敗 | 内容 |", "|---|---|---|---|---|"]
            for r in sub:
                detail = "; ".join(f"{p['check']}: {p['message']}" for p in r["problems"][:2]).replace("|", "\\|")
                out.append(f"| {r['scenario']} | {r['status']} | {r['passed']} | {r['failed']} | {detail} |")
            out.append("")
    return "\n".join(out)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--env", default=str(ROOT / "build/interop"))
    ap.add_argument("--out", default=str(ROOT / "build/interop-nim"))
    ap.add_argument("--builds", default="2026-07-28,2025-11-25,2025-06-18,2025-03-26")
    ap.add_argument("--roles", default="server,client")
    ap.add_argument("--no-build", action="store_true")
    a = ap.parse_args()

    env, out = Path(a.env).resolve(), Path(a.out).resolve()
    suite = env / "conformance/node_modules/@modelcontextprotocol/conformance/dist/index.js"
    if not suite.exists():
        raise SystemExit(f"conformance suite not found in {env}; run peers/setup.sh")
    results, started = [], time.monotonic()
    for v in (b for b in a.builds.split(",") if b):
        # A build that speaks 2026-07-28 also speaks 2025-11-25, so it is checked against both sets.
        for spec in ([v, "2025-11-25"] if v == "2026-07-28" else [v]):
            for role in a.roles.split(","):
                prog = "nim_conformance_server" if role == "server" else "nim_conformance_client"
                reuse = a.no_build or spec != v  # the second pass over a build uses the binary just made
                binary = out / v / prog if reuse else build(v, out, prog)
                resdir = out / "conformance" / f"{role}_{v}_spec{spec}"
                if resdir.exists():
                    subprocess.run(["rm", "-rf", str(resdir)], check=True)
                resdir.mkdir(parents=True)
                server = None
                try:
                    if role == "server":
                        port = free_port()
                        server = subprocess.Popen([str(binary), str(port)], stderr=open(resdir / "server.err", "w"))
                        wait_port(port)
                        cmd = ["node", str(suite), "server", "--url", f"http://127.0.0.1:{port}/mcp", "--suite", "all",
                               "--spec-version", spec, "-o", str(resdir)]
                    else:
                        cmd = ["node", str(suite), "client", "--command", str(binary), "--suite", "all",
                               "--spec-version", spec, "-o", str(resdir)]
                    done = subprocess.run(cmd, capture_output=True, text=True, timeout=1200)
                    (resdir / "console.txt").write_text(ANSI.sub("", done.stdout + done.stderr))
                finally:
                    if server:
                        server.terminate()
                        server.wait()
                rows = summarize(v, spec, role, resdir)
                results += rows
                print(f"{role:6} build {v} spec {spec}: " + ", ".join(
                    f"{s} {sum(1 for r in rows if r['status'] == s)}"
                    for s in ("pass", "warn", "fail", "unsupported", "skipped", "info")), flush=True)
    elapsed = time.monotonic() - started
    (out / "conformance.jsonl").write_text("".join(json.dumps(r, ensure_ascii=False) + "\n" for r in results))
    (out / "conformance.md").write_text(markdown(results, elapsed))
    failing = [r for r in results if r["status"] == "fail"]
    print(f"{len(failing)} failing scenario(s) of {len(results)}; {elapsed:.0f}s; table in {out / 'conformance.md'}")
    return 1 if failing else 0


if __name__ == "__main__":
    sys.exit(main())
