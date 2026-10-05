## Model Context Protocol (MCP) SDK for Nim.
##
## `import mcp` gives the client, the server, the transports and the
## protocol types. The build speaks `DefaultProtocolVersion` and every
## earlier version.

import protocol/types
import protocol/lifecycle
import protocol/modern
import protocol/content
import jsonschema/json_schema
import server/server
import server/tool_output
import client/client
import client/tools
import client/resources
import client/prompts
import client/utilities
import client/roots
import client/sampling
import transport/transport
import transport/stdio
import transport/http
import transport/http_server
import transport/event_stream

export types, lifecycle, modern, content, json_schema
export server, tool_output, client
export tools, resources, prompts, utilities, roots, sampling
export transport, stdio, http, http_server, event_stream

const
  VERSION* = "0.1.0"  ## SDK version

proc getMCPVersion*(): string =
  ## Returns the current version of the MCP Nim SDK
  return VERSION
