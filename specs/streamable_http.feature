Feature: Streamable HTTP transport
  As someone running an MCP server over a network
  I want clients to reach it with HTTP POST
  So that servers and clients need no long-lived connection of their own

  @spec:MCP-HTTP-1 @feature:ftStreamableHttp
  Scenario: The endpoint accepts well-formed JSON-RPC POSTs only
    Given a server's endpoint
    When a request goes to another path, the answer is 404
    And GET or PUT is answered 405 naming the allowed methods
    And a body that is not JSON is 400 with a parse error, and JSON that is not an object is 400 invalid request
    And a body over the limit is 413

  @spec:MCP-HTTP-2 @feature:ftStreamableHttp
  Scenario: Requests from a foreign Origin are refused
    Given a server's endpoint
    When a request has an Origin that is neither loopback nor allowed by the operator
    Then the answer is 403
    And a loopback or allowed Origin is served

  @spec:MCP-HTTP-3 @feature:ftStreamableHttp
  Scenario: Answers carry the security headers and notifications get 202
    Given a server's endpoint
    When any answer is sent
    Then the security headers are present
    And a notification posted on an initialized session is answered 202 with no body

  @spec:MCP-HTTP-4 @feature:ftHttpSessions
  Scenario: A legacy client works inside a session the server issued
    Given a server's endpoint
    When a client initializes
    Then the answer names an unguessable session
    And a second client gets its own session
    And a request without a session id is 400, with an id the server did not issue is 404, with a valid one is served

  @spec:MCP-HTTP-5 @feature:ftHttpSessions
  Scenario: A session ends on DELETE or on a rejected initialize
    Given a server's endpoint
    When the client sends DELETE with its session id
    Then the session ends on the transport and the server
    And DELETE without a session id is 400, with an unknown one is 404
    And an initialize the server rejects opens no session, and past the session limit the answer is 503

  @spec:MCP-HTTP-6 @feature:ftMirroredHeaders
  Scenario: A 2026-07-28 request must carry headers that agree with its body
    Given a server that speaks 2026-07-28
    When the specification's tools/call request is posted with its headers
    Then the answer is 200 with a complete result
    And a header that differs from the body, or a required header that is missing, is 400 header mismatch

  @spec:MCP-HTTP-7 @feature:ftMirroredHeaders
  Scenario: A client mirrors the body into headers
    Given a client of a 2026-07-28 server
    When it sends a request
    Then the request carries Mcp-Method and, where the method has one, Mcp-Name, and no session id

  @spec:MCP-HTTP-8 @feature:ftStreamableHttp
  Scenario: A client connects over HTTP and calls a tool
    Given an HTTP server
    When a client connects
    Then it calls a tool in the newest version both speak
    And against a server limited to a legacy version it falls back to initialize and still calls a tool

  @spec:MCP-HTTP-9 @feature:ftStreamableHttp
  Scenario: A client reads event-stream answers and error bodies
    Given a server that answers with an event stream
    When a request is sent
    Then the notification and the response both arrive in order
    And a stream that ends without the response gives a local stream-closed error
    And an HTTP error with a JSON-RPC error body arrives as the response, under the request's own id
    And an HTTP error without one raises McpTransportError naming the status
