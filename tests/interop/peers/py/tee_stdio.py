"""Wire logger for any stdio MCP server (stdlib only).

Usage: tee_stdio.py LOGFILE CMD [ARGS...]
Runs CMD, relays stdin/stdout unchanged, and appends every line to LOGFILE
prefixed with "C>S " (client to server) or "S>C " (server to client), followed
by "VER ..." lines (see wirelog.py) recording the protocol version each side used.
"""
import subprocess
import sys
import threading

from wirelog import version_lines

log_path, cmd = sys.argv[1], sys.argv[2:]
log = open(log_path, "ab", buffering=0)
child = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE)


def pump(src, dst, tag: bytes) -> None:
    for line in iter(src.readline, b""):
        log.write(tag + line + b"".join(v.encode() + b"\n" for v in version_lines(line)))
        dst.write(line)
        dst.flush()
    dst.close()


threading.Thread(target=pump, args=(child.stdout, sys.stdout.buffer, b"S>C "), daemon=True).start()
pump(sys.stdin.buffer, child.stdin, b"C>S ")
sys.exit(child.wait())
