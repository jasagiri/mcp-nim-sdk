Feature: MCP Transport Mechanisms
  As a MCP SDK user
  I want to use different transport mechanisms
  So that I can connect clients and servers in various environments

  Background:
    Given the MCP protocol version is "2024-11-26"
    And a valid message serialization format using JSON-RPC 2.0

  Scenario: Connect using stdio transport
    Given I have initialized an MCP server/client
    When I configure it with stdio transport
      | inputStream  | outputStream | bufferSize |
      | stdin        | stdout       | 8192       |
    Then the connection should be established successfully
    And the transport should be ready to send and receive messages
    And messages should be properly framed with newlines
    And large messages should be correctly buffered and transmitted

  Scenario: Efficient stdio message buffering
    Given I have a connected stdio transport
    When I send a large message of "5MB" size
    Then the transport should buffer the message appropriately
    And chunk the message if necessary
    And deliver the complete message to the recipient
    And maintain message integrity

  Scenario: Connect using SSE transport
    Given I have initialized an MCP server
    When I configure it with SSE transport
      | endpoint    | port  | headers                         |
      | "/message"  | 8080  | {"Content-Type": "text/event-stream"} |
    Then the server should host an SSE endpoint
    And clients should be able to connect to this endpoint
    And server-to-client messages should be sent as SSE events
    And client-to-server messages should be sent via HTTP POST

  Scenario: SSE transport reconnection
    Given I have a client connected to a server via SSE transport
    When the network connection is temporarily lost for "5" seconds
    Then the client should detect the disconnection
    And attempt to reconnect with exponential backoff
    And successfully restore the connection when available
    And maintain session state during reconnection
    And resume normal operation

  Scenario: Connect using WebSocket transport
    Given I have initialized an MCP server
    When I configure it with WebSocket transport
      | endpoint    | port  | subprotocol   |
      | "/ws"       | 8080  | "mcp-protocol"|
    Then the server should host a WebSocket endpoint
    And clients should be able to connect to this endpoint
    And messages should be sent bidirectionally over WebSocket
    And the transport should handle WebSocket control frames correctly

  Scenario: WebSocket transport connection lifecycle
    Given I have a client connected to a server via WebSocket transport
    When the client initiates a graceful disconnect
    Then the WebSocket should send a proper close frame
    And the server should acknowledge the close frame
    And both sides should clean up their resources
    And report a successful disconnection

  Scenario: Transport error handling
    Given I have a connected transport
    When a network error occurs
      | errorType               | message                   |
      | ConnectionRefused       | "Connection refused"      |
      | NetworkTimeout          | "Connection timed out"    |
      | InvalidMessage          | "Invalid message format"  |
    Then the transport should call the registered error handler
    And provide detailed diagnostic information
    And attempt recovery if configured to do so
    And propagate unrecoverable errors to the application

  Scenario: Transport message validation
    Given I have a connected transport
    When it receives a malformed message
      | message                             | issue                  |
      | {\"broken\": \"json                 | Unterminated string    |
      | {\"jsonrpc\": \"3.0\"}              | Invalid version        |
      | {\"jsonrpc\": \"2.0\", \"id\": 1}   | Missing method/result  |
    Then the transport should reject the message
    And report appropriate validation errors
    And continue processing valid messages
    And maintain protocol integrity

  Scenario: Transport security
    Given I have a server configured with secure transport options
    When a client attempts to connect
    Then the transport should enforce security policies
    And validate client authentication if configured
    And protect against unauthorized access
    And ensure data integrity during transmission
    And handle sensitive information appropriately

  Scenario: Message traffic logging
    Given I have a transport with logging enabled
      | logLevel  | logFormat                       |
      | "debug"   | "{timestamp} {direction} {size}" |
    When messages are sent and received
    Then the transport should log message metadata
    And indicate message direction
    And log message size
    And optionally log message content for debugging
    And redact sensitive information from logs

  Scenario: Transport diagnostics
    Given I have a connected transport
    When I request transport diagnostics
    Then I should receive diagnostic information including:
      | metric                | description                     |
      | "bytesReceived"       | Total bytes received            |
      | "bytesSent"           | Total bytes sent                |
      | "messagesReceived"    | Count of messages received      |
      | "messagesSent"        | Count of messages sent          |
      | "connectionDuration"  | Time since connection           |
      | "errorCount"          | Number of errors encountered    |
      | "currentState"        | Current transport state         |

  Scenario: Transport factory
    Given I need to create appropriate transports based on URIs
    When I request a transport for the following URIs
      | uri                           | expectedType      |
      | "stdio://"                    | "StdioTransport"  |
      | "http://localhost:8080/events"| "SSETransport"    |
      | "ws://localhost:8080/mcp"     | "WebSocketTransport" |
    Then the factory should create the correct transport type
    And configure it with the appropriate parameters
    And the transport should be ready to connect