## Interactive Roots Browser Client
##
## This example demonstrates how to use the MCP client to interact with roots.
##
## NOTE: This example requires the roots functionality to be implemented in the client.
## Currently this is a stub showing what the API would look like.

import asyncdispatch, json, options, strutils
import std/terminal
import ../../src/mcp

proc printHeader(title: string) =
  ## Print a formatted header
  styledEcho fgCyan, "\n=== ", title, " ==="
  echo ""

proc printColored(text: string, color: ForegroundColor = fgDefault) =
  ## Print text with color
  styledEcho color, text

proc main() {.async.} =
  printHeader("MCP Roots Client Example")
  
  echo "This example demonstrates the roots API."
  echo "The listRoots functionality is not yet implemented in the client."
  echo ""
  echo "In a full implementation, this client would:"
  echo "1. Connect to a server with roots capability"
  echo "2. Call client.listRoots() to get available roots"
  echo "3. Allow browsing of the root hierarchy"
  echo ""
  echo "Please check the roots_server.nim example for server-side implementation."

# Run the main procedure when script is executed
when isMainModule:
  waitFor main()