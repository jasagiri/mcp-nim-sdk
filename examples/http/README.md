# HTTP Transport Examples for MCP

This directory contains examples of using HTTP as a transport mechanism for the Model Context Protocol (MCP).

## Overview

These examples demonstrate a streamable HTTP transport implementation for MCP, with both server and client components. The HTTP transport offers several advantages:

- **Web compatibility**: Can be deployed on standard web servers and accessed through firewalls
- **Bi-directional communication**: Supports both streaming (Server-Sent Events) and polling modes
- **Stateful sessions**: Manages client sessions for persistent connections
- **Scalability**: Can be deployed behind load balancers and proxies

## Files

- `http_server.nim`: An HTTP server implementation for MCP
- `http_client.nim`: A client that connects to the HTTP server using streamable HTTP transport

## HTTP Server

The HTTP server implements the following endpoints:

- `POST /session`: Create a new session
- `DELETE /session?sessionId=X`: Delete a session
- `POST /message?sessionId=X`: Send a message to the server
- `GET /stream?sessionId=X`: Streaming endpoint (Server-Sent Events)
- `GET /poll?sessionId=X`: Polling endpoint for clients that don't support streaming

The server also provides two example MCP capabilities:

1. A text resource at `example://text`
2. Two tools:
   - `getCurrentTime`: Returns the current server time
   - `echo`: Echoes back a message

## HTTP Client

The client demonstrates how to:

1. Connect to the HTTP server using the streamable HTTP transport
2. List available resources
3. Read the content of a resource
4. List available tools
5. Call tools with arguments
6. Interactive mode to send messages to the echo tool

## Running the Examples

First, start the server:

```
nim c -r http_server.nim
```

Then, in another terminal, run the client:

```
nim c -r http_client.nim
```

## Architecture

```
┌────────────┐      HTTP      ┌────────────┐
│            │◄──────────────►│            │
│  MCP       │                │  MCP       │
│  Client    │  Streamable    │  Server    │
│            │  HTTP Transport│            │
└────────────┘                └────────────┘
```

The streamable HTTP transport works in two modes:

1. **Streaming Mode**: Uses Server-Sent Events (SSE) for real-time updates from server to client
2. **Polling Mode**: Falls back to periodic polling if streaming is not supported

Messages from client to server are always sent as HTTP POST requests.

## Session Management

The server implements session management with the following features:

- Unique session IDs for each client
- Session timeouts (sessions expire after inactivity)
- Session cleanup to prevent memory leaks
- Session-specific message queues for reliable delivery

## Error Handling

Both the server and client implement comprehensive error handling:

- Connection errors
- Parsing errors
- Request/response errors
- Session management errors
- Tool execution errors

## Security Considerations

In a production environment, consider implementing:

- Authentication and authorization
- TLS encryption
- Input validation
- Rate limiting
- CORS headers for web clients

## Extensions

This example could be extended with:

- WebSocket support for more efficient bi-directional communication
- Authentication and authorization
- Multiple concurrent clients
- More advanced MCP capabilities (more complex tools and resources)
- Request/response logging and monitoring
