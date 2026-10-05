## Model Context Protocol (MCP) SDK for Nim.
##
## `import mcp` gives the client, the server, the transports and the
## protocol types. The build speaks `DefaultProtocolVersion` and every
## earlier version.

import protocol/types
import protocol/lifecycle
import protocol/modern
import server/server
import client/client
import transport/transport
import transport/stdio
import transport/http
import transport/http_server
import transport/event_stream

export types, lifecycle, modern
export server, client
export transport, stdio, http, http_server, event_stream

const
  VERSION* = "0.1.0"  ## SDK version

proc getMCPVersion*(): string =
  ## Returns the current version of the MCP Nim SDK
  return VERSION
