Feature: HTTP with Server-Sent Events (2024-11-05)
  As someone whose client or server speaks the first MCP transport over HTTP
  I want the SSE connection and the POST endpoint to work as 2024-11-05 describes them
  So that older peers still connect

  Specification: 2024-11-05 basic/transports, "HTTP with SSE". The client opens
  an SSE connection; the server's first event, endpoint, names the URI the
  client posts its messages to; the server's messages arrive as message
  events. Streamable HTTP replaced it in 2025-03-26, which describes how a
  client falls back to it (basic/transports, "Backwards Compatibility").

  @spec:MCP-HTTPSSE-1 @feature:ftHttpSse
  Scenario: A server opens an event stream and names the endpoint to post to
    Given a server with the HTTP+SSE transport
    When a client sends GET on the SSE path
    Then the answer is an event stream whose first event is endpoint, naming the URI to post to
    And two connections are given different endpoints

  @spec:MCP-HTTPSSE-2 @feature:ftHttpSse
  Scenario: Answers arrive on the stream and the POST is only acknowledged
    Given a connected client
    When it posts a request to the endpoint
    Then the POST is answered 202 and the response arrives on the stream
    And a notification the server sent during the request arrives before the response
    And two clients using the same request id each get their own answer

  @spec:MCP-HTTPSSE-3 @feature:ftHttpSse
  Scenario: The server speaks to the client on the stream too
    Given connected clients
    When the server sends a notification to every client, or a request to one that answers by POST
    Then each client hears the notification, and the server receives the answer

  @spec:MCP-HTTPSSE-4 @feature:ftHttpSse
  Scenario: A POST the server cannot accept is refused
    Given a server with the HTTP+SSE transport
    When a POST names no session or an unknown one, is not JSON, or is JSON that is not an object
    Then the answers are 400 or 404, 400 and 400

  @spec:MCP-HTTPSSE-5 @feature:ftHttpSse
  Scenario: A connection lasts as long as its stream
    Given a connected client
    When it closes its stream
    Then the session ends and its endpoint is gone
    And past the session limit another client is answered 503

  @spec:MCP-HTTPSSE-6 @feature:ftHttpSse
  Scenario: The server refuses a foreign Origin and sends the security headers
    Given a server with the HTTP+SSE transport
    When a request comes from a foreign Origin
    Then the answer is 403, whether it connects or posts
    And the stream's head carries the security headers

  @spec:MCP-HTTPSSE-7 @feature:ftHttpSse
  Scenario: A client connects, posts to the endpoint and reads the stream
    Given a server with the HTTP+SSE transport
    When a client connects
    Then it posts to the endpoint the server named, receives each answer and each related notification, and answers the server's requests by POST
    And a notification sent first reaches the server
    And headers the application set go on the stream request and on every POST

  @spec:MCP-HTTPSSE-8 @feature:ftHttpSse
  Scenario: A client does not trust what the stream tells it
    Given a client that connects
    When the endpoint event names another host, the server never sends an endpoint, or answers the stream request with 404
    Then the client refuses to post there, gives up with a transport error, or reports the status

  @spec:MCP-HTTPSSE-9 @feature:ftHttpSse
  Scenario: A client sees the end of the stream
    Given a connected client
    When the stream ends while it waits, or the client was closed
    Then waiting raises a transport-closed error, and sending raises a transport error

  @spec:MCP-HTTPSSE-10 @feature:ftHttpSse
  Scenario: A client given the URL of an older server falls back to the old transport
    Given a client that tries Streamable HTTP first
    When the server only speaks HTTP+SSE
    Then the client falls back and initialize and tools/list work
    And a Streamable HTTP server is used as one, and headers set on the client are carried by the fallback
    And a server that is down is an error, not a reason to fall back
