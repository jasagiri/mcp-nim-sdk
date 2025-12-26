# Model Context Protocol (MCP) Server SDK for Nim
#
# File Server Example - A server that provides file resources.

import unittest, asyncdispatch, json, options, os, tables
import ../src/mcp/types
import ../src/mcp/protocol

suite "File Server Tests":
  test "Server creation with resource capabilities":
    let metadata = types.ServerMetadata(
      name: "file-server",
      version: "1.0.0"
    )

    let capabilities = types.ServerCapabilities(
      resources: some(types.ResourcesCapability(listChanged: some(true)))
    )

    let server = newServer(metadata, capabilities)

    check(server.name == "file-server")
    check(server.version == "1.0.0")
    check(server.capabilities.resources.isSome)

  test "File resource registration":
    let metadata = types.ServerMetadata(name: "file-server", version: "1.0.0")
    let capabilities = types.ServerCapabilities(
      resources: some(types.ResourcesCapability())
    )
    var server = newServer(metadata, capabilities)

    # Register a file resource
    server.registerResource(
      "file:///etc/hosts",
      "Hosts File",
      "System hosts file",
      "text/plain"
    )

    check(server.resources.contains("file:///etc/hosts"))
    check(server.resources["file:///etc/hosts"].name == "Hosts File")

  test "Multiple resource registration":
    let metadata = types.ServerMetadata(name: "file-server", version: "1.0.0")
    let capabilities = types.ServerCapabilities(
      resources: some(types.ResourcesCapability())
    )
    var server = newServer(metadata, capabilities)

    server.registerResource("file:///path/to/file1.txt", "File 1", "First file", "text/plain")
    server.registerResource("file:///path/to/file2.json", "File 2", "Second file", "application/json")
    server.registerResource("file:///path/to/image.png", "Image", "An image", "image/png")

    check(server.resources.len == 3)
    check(server.resources.contains("file:///path/to/file1.txt"))
    check(server.resources.contains("file:///path/to/file2.json"))
    check(server.resources.contains("file:///path/to/image.png"))
    check(server.resources["file:///path/to/file2.json"].mimeType == "application/json")

  test "Resource with binary content type":
    let metadata = types.ServerMetadata(name: "file-server", version: "1.0.0")
    let capabilities = types.ServerCapabilities(
      resources: some(types.ResourcesCapability())
    )
    var server = newServer(metadata, capabilities)

    server.registerResource(
      "file:///path/to/binary.bin",
      "Binary File",
      "A binary file",
      "application/octet-stream"
    )

    check(server.resources["file:///path/to/binary.bin"].mimeType == "application/octet-stream")
