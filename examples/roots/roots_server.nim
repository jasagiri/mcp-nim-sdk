# Model Context Protocol (MCP) Server SDK for Nim
#
# Example server using the Roots capability

import asyncdispatch, json, options, os, strutils, tables
import ../../src/mcp

# Create a roots-enabled server
proc createRootsServer(): tuple[server: Server, rootManager: RootManager] =
  let metadata = types.ServerMetadata(
    name: "example-roots-server",
    version: "1.0.0"
  )
  
  var rootsCap = RootsCapability(
    listChanged: some(true)
  )
  
  var capabilities = ServerCapabilities(
    roots: some(rootsCap)
  )
  
  let server = newServer(metadata, capabilities)
  let rootManager = newRootManager()
  
  return (server: server, rootManager: rootManager)

# Main procedure
proc main() {.async.} =
  # Create the server and root manager
  let (server, rootManager) = createRootsServer()
  
  # Add some roots
  discard rootManager.addRoot("file:///home/user", "User Files", "User home directory files")
  discard rootManager.addRoot("file:///etc", "Configuration Files", "System configuration files")
  discard rootManager.addRoot("file:///var/log", "Log Files", "System log files")
  
  # Define custom roots for demonstration
  discard rootManager.addRoot("project://src", "Source Code", "Project source code")
  discard rootManager.addRoot("project://docs", "Documentation", "Project documentation")
  discard rootManager.addRoot("db://localhost", "Local Database", "Local database connection")
  
  # Connect to standard I/O transport
  let transport = newStdioTransport()
  
  echo "Starting MCP Roots server on stdio..."
  echo "This server demonstrates the Roots capability of MCP"
  echo ""
  
  # Set up transport
  await server.connect(transport)
  
  echo "Server is running. Available roots:"
  for uri, root in rootManager.roots:
    echo "  - ", root.name, " (", uri, ")"
    if root.description.isSome:
      echo "    ", root.description.get()
  echo ""
  
  # Keep server running
  while true:
    await sleepAsync(100)

# Run the main procedure when script is executed
when isMainModule:
  waitFor main()