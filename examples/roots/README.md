# MCP Roots Example

This directory contains examples of server and client implementations that utilize the Roots feature of MCP.

## What is the Roots Feature?

The Roots feature allows MCP servers to expose root directories or URL trees of resources. Clients can explore resources from these roots. This enables servers to provide a hierarchical structure of resources, and clients can browse resources in a file system-like manner.

## About This Sample

This sample consists of two components:

1. **roots_server.nim** - An MCP server that exposes multiple roots
2. **roots_client.nim** - An interactive client that browses the roots exposed by the server

## Usage

### Starting the Server

```bash
nim c -r roots_server.nim
```

The server exposes the following roots:
- `file:///home/user` - User's home directory
- `file:///etc` - System configuration files
- `file:///var/log` - Log files
- `project://src` - Sample project source code (custom root)
- `project://docs` - Sample project documentation (custom root)
- `db://localhost` - Database (custom root)

### Running the Client

From another terminal, run the client:

```bash
nim c -r roots_client.nim
```

The client provides an interactive interface. The following commands are available:

- `list` - List all available roots
- `browse <root_uri> [path]` - Browse the contents of the specified root and path
- `help` - Display a list of available commands
- `exit` or `quit` - Exit the client

Example:
```
> list
=== Roots List ===
Root: file:///home/user
  Description: User Files
Root: file:///etc
  Description: Configuration Files
...

> browse file:///home/user
=== Browsing file:///home/user ===
[DIR] Documents
[DIR] Downloads
[FILE] .bashrc
...
```

## Implementing Custom Roots Feature

To implement your own Roots feature in an MCP server:

1. Include RootsCapability when initializing the server:
   ```nim
   var capabilities = ServerCapabilities(
     roots: some(RootsCapability())
   )
   ```

2. Add roots:
   ```nim
   server.addRoot("custom://path", some("Description"))
   ```

3. Optionally add a custom browser implementation:
   ```nim
   proc customRootBrowser(uri: string, path: string): Future[seq[RootItem]] {.async.} =
     # Implement custom logic here
     result = @[
       RootItem(name: "item1", isDirectory: false),
       RootItem(name: "folder", isDirectory: true)
     ]
   
   server.registerRootBrowser("custom://", customRootBrowser)
   ```

## Extending the Sample

This sample can be extended in the following ways:

1. Adding custom root types and implementing corresponding browsers
2. More complex file system operations (reading and writing files, etc.)
3. Implementing a database browser
4. Displaying resource metadata (size, modification date, etc.)

## Related Documentation

For more details, please refer to `docs/roots_best_practices.md`.

## Protocol Versioning Support

This example demonstrates compatibility with both MCP protocol versions:
- 2024-11-05 (semantic versioning format)
- 2025-03-26 (date-based versioning)

The server automatically negotiates the appropriate protocol version with clients.