Feature: Streamable HTTP Transport
  As a MCP SDK developer
  I want to implement Streamable HTTP Transport
  So that clients and servers can communicate over HTTP with streaming capabilities

  Background:
    Given the MCP protocol version is "2025-03-26"
    And the transport implements JSON-RPC 2.0 message format
    
  Scenario: Client connecting to server using Streamable HTTP
    Given a client configured to use Streamable HTTP transport
    And a server endpoint "http://localhost:8080/mcp"
    When the client connects to the server
    Then the connection should be established successfully
    And the client should be able to send initialization request
    And the client should receive initialization response
    And the response should include a session ID header

  Scenario: Client sends a request using HTTP POST
    Given a client with an established Streamable HTTP connection
    And a valid session ID "session123"
    When the client sends a request
      | jsonrpc | id | method      | params       |
      | "2.0"   | 1  | "test/echo" | {"text":"hello"} |
    Then the server should receive the request successfully
    And the server should include the session ID header in the request
    And the server should return either a direct response or an SSE stream

  Scenario: Server responds with direct JSON response
    Given a client has sent a request to the server
    When the server decides to respond directly
    Then the server should return HTTP 200 OK
    And set Content-Type to "application/json"
    And include a JSON-RPC response in the body
    And the client should successfully process the response

  Scenario: Server responds with an SSE stream
    Given a client has sent a request to the server
    When the server decides to respond with streaming
    Then the server should return HTTP 200 OK
    And set Content-Type to "text/event-stream"
    And start sending SSE events
    And include event IDs in the SSE events
    And eventually include a response to the original request
    And the client should process all SSE events
    And the client should match responses to their original requests
    
  Scenario: Client establishes a listening connection with HTTP GET
    Given a client with an established session
    When the client sends an HTTP GET to the MCP endpoint
    And includes the session ID header
    Then the server should establish an SSE stream
    And allow sending requests and notifications to the client
    And the client should process incoming server messages

  Scenario: Client handles stream disconnection and resumption
    Given a client is connected to an SSE stream
    And has received several events with IDs
    When the connection is interrupted
    And the client attempts to reconnect
    Then the client should include the Last-Event-ID header
    And the server should resume the stream from that point
    And resend any missed messages from that stream

  Scenario: Handling batched requests and responses
    Given a client with an established connection
    When the client sends a batch of multiple requests
      | jsonrpc | id | method       | params        |
      | "2.0"   | 1  | "test/echo1" | {"text":"hi"} |
      | "2.0"   | 2  | "test/echo2" | {"num":42}    |
    Then the server should process all requests in the batch
    And may return responses either as batch or individually in the stream
    And the client should match all responses to their requests

  Scenario: Server session management
    Given a client that has completed initialization
    And received a session ID "session123"
    When the client sends subsequent requests
    Then each request must include the session ID header
    And if the client omits the session ID
    Then the server should respond with HTTP 400 Bad Request
    And if the client provides an expired session ID
    Then the server should respond with HTTP 404 Not Found
    And the client should reinitialize the session

  Scenario: Client explicitly terminates session
    Given a client with an active session
    When the client no longer needs the session
    And sends an HTTP DELETE to the MCP endpoint
    And includes the session ID header
    Then the server should terminate the session
    And respond with HTTP 200 OK
    And future requests with that session ID should be rejected
