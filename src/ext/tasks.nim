## The official Tasks extension, `io.modelcontextprotocol/tasks`, for MCP
## 2026-07-28: a server answers a `tools/call` with a task handle, the client
## polls it, gives it input and cancels it.
##
## Not part of `import mcp`, and off until used: only a server or client that
## calls `enableTasksExtension` declares it, which needs a build that speaks
## 2026-07-28. See `ext/tasks/server` and `ext/tasks/client`; the way a task
## is written on the wire is `ext/tasks/wire`. Based on the specification
## ext-tasks@5246bc3d0253c1c4b09e682f690b7e8b97362500.
##
## Import it as `import ext/tasks`. `enableTasksExtension` is one name for
## both sides: it takes a `McpServer` or a `McpClient`.

import ./tasks/wire
import ./tasks/server
import ./tasks/client

export wire, server, client
