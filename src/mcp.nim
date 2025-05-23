## Main package file for the Model Context Protocol (MCP) Nim SDK.
##
## This module provides access to all MCP functionality including client,
## server, resources, tools, and transports.

import mcp/protocol
import mcp/client
import mcp/server
import mcp/resources
import mcp/tools
import mcp/sampling
import mcp/types
import mcp/roots
import mcp/transport/base
import mcp/transport/stdio
import mcp/transport/sse

export protocol
export client
export server
export resources
export tools
export sampling
export types
export roots
export base
export stdio
export sse

const
  VERSION* = "0.1.0"  ## SDK version

proc getMCPVersion*(): string =
  ## Returns the current version of the MCP Nim SDK
  return VERSION
