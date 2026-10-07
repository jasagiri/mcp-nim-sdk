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

  @spec:MCP-HTTP-24
  Scenario: A schema keyword that holds schemas but no annotation does not invalidate a tool, and an invalid one is explained
    Given an input schema with items, additionalProperties, anyOf and a property named x-mcp-header, none of them annotated
    When declarations are read from it
    Then the tool is valid and only the annotated property is bound
    And for an invalid declaration the reason names the property or the schema root it was found on
    And the reason for an empty name says the name must not be empty

  @spec:MCP-HTTP-25
  Scenario: Which argument values a header can mirror
    Given an integer property annotated with x-mcp-header
    When the argument is 2^53-1 or -(2^53-1), the header is built
    And a body number written as 42.0 agrees with the header 42
    And an object or array argument agrees with no header value

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


  @spec:MCP-HTTP-19 @feature:ftStreamableHttp
  Scenario: Only an initialize request opens a session
    Given a server that keeps a session for every client that initializes
    When a message named initialize but without an id is posted, with no session
    Then the answer is 400 for the missing session and no session is made

  @spec:MCP-HTTP-20 @feature:ftStreamableHttp
  Scenario: A POST answered with a JSON body ends the connection
    Given a POST that the server answers with a plain JSON body
    When the answer is complete
    Then the server closes the connection, so that nothing the client sends next is read by the watcher of a finished exchange

  @spec:MCP-HTTP-21 @feature:ftStreamableHttp
  Scenario: A server that speaks 2026-07-28 alone refuses batches and accepts notifications
    Given a server that speaks 2026-07-28 and nothing older
    When a batch is posted, even one whose first message is a complete 2026-07-28 request
    Then the answer is 400 invalid request
    And a notification is answered 202, whatever its method is named and whichever version it names

  @spec:MCP-HTTP-22
  Scenario: A document without a validator is served whole whatever the client holds
    Given a fixed document served without an ETag
    When a client GETs it with If-None-Match
    Then the answer is 200 with the body and no ETag header

  @spec:MCP-HTTP-23
  Scenario: Starting a server transport binds it and serves until it is closed
    Given a server transport that is not listening
    When it is started
    Then its port is bound at once and it answers requests
    And the start ends only when the transport is closed

  @spec:MCP-HTTP-g2g-hc-b-1
  Scenario: A request that is over is forgotten, and cancelling it does nothing
    Given a request that was answered with a JSON body or an event stream, failed after the connection was made, or was cancelled while the server was silent or its body was arriving
    When the client cancels it afterwards and sends the same id again
    Then the new request is not taken for a cancelled one: when its stream ends without a response, the stream-closed error is delivered

  @spec:MCP-HTTP-g2g-hc-b-2
  Scenario: Closing the transport ends the event streams it has open
    Given a request whose answer is an event stream that is still open
    When the transport is closed
    Then the server sees the client leave

  @spec:MCP-HTTP-g2g-hc-b-3
  Scenario: An answer without a body ends the connection
    Given a server that answers a notification with 202, or DELETE with 204, and sends no body
    When the client has the answer
    Then the client closes the connection and does not leave it open

  @spec:MCP-HTTP-g2g-hc-b-4 @feature:ftHttpGetStream
  Scenario: The GET stream is opened once
    Given a session whose GET stream is open
    When the client says initialized again
    Then no second GET stream is opened

  @spec:MCP-HTTP-g2g-hc-b-5 @feature:ftHttpSessions
  Scenario: A refusal of DELETE is logged unless the server may refuse it
    Given a session that the client ends by closing
    When the server answers DELETE with 500, or drops the connection
    Then the refusal or the failure is logged and closing succeeds
    And an answer of 204 or 405 is not logged

  @spec:MCP-HTTP-g2g-hc-b-6
  Scenario: A notification names the protocol version only in the versions that have the header
    Given a transport that negotiated a version
    When it sends a notification
    Then MCP-Protocol-Version is present for 2025-06-18 and 2025-11-25 and absent for 2024-11-05, 2025-03-26 and 2026-07-28

  @spec:MCP-HTTP-g2g-hc-b-7
  Scenario: Authorization is retried at most three times per request
    Given a hook that always says it improved things and a server that keeps refusing
    When a request is sent
    Then it is posted four times in all and McpAuthorizationError counts three attempts

  @spec:MCP-HTTP-g2g-hc-b-8 @feature:ftParameterHeaders
  Scenario: Only a call that names 2026-07-28 and a tool carries Mcp-Param headers
    Given a transport that listed a tool with x-mcp-header
    When a tools/call is sent whose _meta lacks the version or names another, or that names no tool
    Then it is posted without Mcp-Param headers, and without failing
    And an answer to anything but a tools/list that was sent is not read as a tool list

  @spec:MCP-HTTP-g2g-hc-a-1
  Scenario: The client mirrors the x-mcp-header declarations of the latest tools/list answer
    Given a client that listed a tool declaring x-mcp-header
    When a later listing declares the tool invalid, or without the header, a call no longer carries Mcp-Param-Region
    And a second answer under the same id, or a request of the server with that id, is not the answer to the listing
    And a tool left out of a listing is named in the log
    And an answer that has no tools array is handed over as it is

  @spec:MCP-HTTP-g2g-hc-a-2
  Scenario: A response is accepted up to the limit, and an HTTP error is a JSON-RPC answer only if its body is one
    Given a client with a limit on the size of a response
    When a response is exactly as long as the limit, it is delivered
    And an HTTP error whose body has no jsonrpc version, or is no object, is a transport error carrying the status

  @spec:MCP-HTTP-g2g-hc-a-3
  Scenario: A request whose stream ends without its response is answered by a local error, and only then
    Given a request answered on an event stream
    When the stream carries the response and ends, nothing else is delivered
    And when it ends without it, the stream-closed error follows, whatever else it carried, even a request of the server with the same id
    And a transport that was closed delivers none, and a cancelled id can be used again

  @spec:MCP-HTTP-g2g-hc-a-4
  Scenario: The client closes the connection of a stream that ends and says why a stream failed
    Given event streams of a request and of the GET
    When an event is no JSON, the connection is closed and one log line names the failure
    And a GET answered other than by an event stream is closed, logged unless it is 405, and not asked again
    And closing the transport closes the connection of an open GET stream, also of one that was still being opened
    And every request after the negotiation of a version with the header, the GET and the DELETE included, names that version

  @spec:MCP-HTTP-g2g-hc-a-5
  Scenario: A POST stream is resumed from the last event id, however often it breaks while the server is working
    Given a stream broken before the response
    When a resumed stream carries no ids, the next resumption names the last id that was sent
    And a stream that delivers something resets the count of attempts
    And a resumed stream that carries the response ends the resumption

  @spec:MCP-HTTP-g2g-hc-a-6
  Scenario: The GET stream is opened once, reopened after a delay, and given up after the reconnect limit
    Given a session that has a GET stream
    When every stream ends at once, the client asks once and as often again as it may reconnect
    And it waits for the reconnect delay, and names the last id that was sent
    And a second initialization opens no second stream while one is open, and asks again after one ended
