## What an authorization server names ends up in a diagnostic line only as
## escapes and cut short (MCP-SEC-HTTP-7).

import std/[unittest, asyncdispatch, asyncnet, httpcore, os, strutils]
import auth/oauth/[fetch, urls, errors]

proc loggedWhile(body: proc()): string =
  ## Everything the code under test wrote to stderr.
  let path = getTempDir() / "mcp-sec-diagnostic-auth-" & $getCurrentProcessId() & ".log"
  let saved = stderr
  stderr = open(path, fmWrite)
  try:
    body()
  finally:
    stderr.close()
    stderr = saved
  result = readFile(path)
  removeFile(path)

proc silentServer(): string =
  ## A server that takes the connection and never answers; the URL it
  ## returns ends in a very long path, as a metadata document can name one.
  let listener = newAsyncSocket()
  listener.setSockOpt(OptReuseAddr, true)
  listener.bindAddr(Port(0), "127.0.0.1")
  listener.listen()
  let port = listener.getLocalAddr()[1]
  proc hold() {.async.} =
    let socket = await listener.accept()
    await sleepAsync(500)
    socket.close()
    listener.close()
  asyncCheck hold()
  "http://127.0.0.1:" & $port.int & "/" & "p".repeat(5000)

suite "peer text in the diagnostics of the authorization code (MCP-SEC-HTTP-7)":
  test "Given an endpoint with a very long URL that never answers, when the request is abandoned and ends, then the log line is short":
    let url = silentServer()
    var policy = defaultFetchPolicy()
    policy.timeoutMs = 50
    let logged = loggedWhile(proc() =
      expect OAuthError:
        discard waitFor httpExchange(HttpGet, url, policy, "token endpoint")
      waitFor sleepAsync(700))
    check "[oauth] abandoned request" in logged
    check logged.count('\n') == 1
    check logged.len < 1000
