Feature: Streamable HTTP transport
  As someone running an MCP server over a network
  I want clients to reach it with HTTP POST
  So that servers and clients need no long-lived connection of their own

  @spec:MCP-HTTP-1 @feature:ftStreamableHttp
  Scenario: The endpoint accepts well-formed JSON-RPC POSTs only
    Given a server's endpoint
    When a request goes to another path, the answer is 404
    And a method the endpoint does not serve, such as PUT, is answered 405 naming the allowed methods
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

  @spec:MCP-HTTP-10 @feature:ftParameterHeaders
  Scenario: A server checks the Mcp-Param headers of a tool call against its arguments
    Given a server with a tool whose input schema marks a property with x-mcp-header
    When a call carries the Mcp-Param header with the argument's value, plain or in the Base64 form
    Then the answer is 200
    And a header that differs, or is missing though the argument is there, or is sent though the argument is not, is 400 header mismatch
    And an argument that is null or absent expects no header

  @spec:MCP-HTTP-11 @feature:ftParameterHeaders
  Scenario: Invalid x-mcp-header declarations keep a tool out of the list
    Given tools of which one declares x-mcp-header on a number, a duplicate name or an unreachable property
    When the server lists tools, it leaves the invalid tool out
    And a client that is handed such a list drops the invalid tool and keeps the others

  @spec:MCP-HTTP-12 @feature:ftParameterHeaders
  Scenario: A client mirrors the arguments of a tool call into Mcp-Param headers
    Given a client that has listed the tools of a 2026-07-28 server
    When it calls a tool with x-mcp-header properties
    Then the request carries one Mcp-Param header per argument present, encoded as the specification says
    And an argument that cannot be mirrored is refused before anything is sent

  @spec:MCP-HTTP-13 @feature:ftParameterHeaders
  Scenario: Which tool declarations are valid
    Given the rules for x-mcp-header values and the properties they may sit on
    When declarations are read from an input schema
    Then a token name on a string, integer or boolean property reachable through properties keys is valid
    And every other declaration makes the tool invalid

  @spec:MCP-HTTP-14 @feature:ftMirroredHeaders
  Scenario: The version header also tells a 2026-07-28 request from an older one
    Given a server that speaks 2026-07-28
    When a request names 2026-07-28 in its version header but lacks the per-request fields in the body
    Then the answer is 400 invalid params, not an error about sessions
    And an Mcp-Name with spaces or tabs around it is read without them

  @spec:MCP-HTTP-15 @feature:ftStreamableHttp
  Scenario: GET and DELETE exist only where a spoken version has them
    Given a server's endpoint
    When a GET or DELETE names no version and no session
    Then GET is 400 where a spoken version has the stream, and DELETE is 400 where a spoken version has the initialize handshake, since the session id is what is missing
    And it is 405 where none has, and Allow names the methods the spoken versions use
    And a GET or DELETE that names 2026-07-28 is 405 with Allow: POST, whatever else the server speaks

  @spec:MCP-HTTP-16 @feature:ftPerRequestMetadata
  Scenario: A server that speaks 2026-07-28 alone ignores the mechanisms of earlier revisions
    Given a build whose oldest version is 2026-07-28
    When a request carries Mcp-Session-Id and Last-Event-ID
    Then both are ignored and no session id comes back
    And a posted initialize is answered 400 naming the versions the server speaks
    And the HTTP+SSE paths do not exist

  @spec:MCP-HTTP-17 @feature:ftStreamableHttp
  Scenario: A client's timeouts hold against a server that never answers
    Given a server that accepts the connection and never answers
    When a client connects, or sends a request with a timeout
    Then McpTimeoutError is raised after the timeout instead of waiting forever

  @spec:MCP-HTTP-18 @feature:ftParameterHeaders
  Scenario: A client refused for its parameter headers lists the tools again and retries once
    Given a tool whose x-mcp-header declarations changed after the client listed it
    When the call is refused as a header mismatch
    Then the client reads tools/list again and retries the call with the headers the tool declares now
    And a second refusal is returned to the caller without another retry


  @spec:MCP-HTTP-g2f-hs-b-1 @feature:ftStreamableHttp
  Scenario: Only an initialize request opens a session
    Given a server that keeps a session for every client that initializes
    When a message named initialize but without an id is posted, with no session
    Then the answer is 400 for the missing session and no session is made

  @spec:MCP-HTTP-g2f-hs-b-2 @feature:ftStreamableHttp
  Scenario: A POST answered with a JSON body ends the connection
    Given a POST that the server answers with a plain JSON body
    When the answer is complete
    Then the server closes the connection, so that nothing the client sends next is read by the watcher of a finished exchange

  @spec:MCP-HTTP-g2f-hs-b-3 @feature:ftStreamableHttp
  Scenario: A server that speaks 2026-07-28 alone refuses batches and accepts notifications
    Given a server that speaks 2026-07-28 and nothing older
    When a batch is posted, even one whose first message is a complete 2026-07-28 request
    Then the answer is 400 invalid request
    And a notification is answered 202, whatever its method is named and whichever version it names
