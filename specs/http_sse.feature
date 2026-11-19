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
    And the status decides whatever the length of the body of an answer: an error is reported with its status, a 2xx is a success, and a body past the limit is not read to its end

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

  @spec:MCP-HTTPSSE-11 @feature:ftHttpSse
  Scenario: The two paths of the transport belong together
    Given a server with the HTTP+SSE transport whose SSE path is switched off
    When a client POSTs to the messages path, or GETs the messages path while the transport is on
    Then the first answer is 404, as the path does not exist
    And the second is 405 naming POST

  @spec:MCP-HTTPSSE-12 @feature:ftHttpSse
  Scenario: A client takes an endpoint only from the origin it asked
    Given a client that connects
    When the endpoint event names another scheme, another host or another port
    Then the client refuses it with a transport error naming the endpoint, as soon as it is read
    And a relative endpoint is resolved against the stream's URL by RFC 3986 section 5.2, its dot segments removed

  @spec:MCP-HTTPSSE-13 @feature:ftHttpSse
  Scenario: A stream that ends before it names an endpoint fails the connection at once
    Given a client that connects
    When the stream ends without an endpoint event
    Then the client raises a transport error saying so, without waiting out its connect timeout

  @spec:MCP-HTTPSSE-14 @feature:ftHttpSse
  Scenario: Only message events with data are messages
    Given a client reading a stream
    When an event of another type, or a message event without data, arrives
    Then the client skips it and delivers the next message

  @spec:MCP-HTTPSSE-15 @feature:ftHttpSse
  Scenario: A client that waits after the stream ended is told so
    Given a stream that ended some time ago
    When the client waits for a message
    Then waiting raises a transport-closed error at once

  @spec:MCP-HTTPSSE-16 @feature:ftHttpSse
  Scenario: A client lets go of every connection it is done with
    Given a client and a server that leaves closing to it
    When the stream fails, the stream request is refused or is no event stream, no endpoint comes in time, a POST is answered, or the client is closed
    Then the client closes its end of that connection

  @spec:MCP-HTTPSSE-17 @feature:ftHttpSse
  Scenario: A stream that fails is reported on stderr
    Given a client reading a stream
    When the stream fails on a message that is not JSON
    Then a line naming the stream and the failure goes to stderr
    And a stream the client closes itself, because no endpoint came in time, is not reported as failed: the failure is the one the send raises

  @spec:MCP-HTTPSSE-18
  Scenario: The wrapper that tries Streamable HTTP first passes everything on to the transport it chose
    Given a client that tries Streamable HTTP first
    When a notification or a response is sent after the fallback, a version is agreed, or the wrapper is closed with or without a session, or before it has chosen
    Then the chosen transport sends it, receives the agreed version, and ends its session or stream, and a receive that waits fails when the wrapper is closed

  @spec:MCP-HTTPSSE-19 @feature:ftHttpSse
  Scenario: A message event larger than the client allows is not delivered
    Given a client of the old transport whose maxResponseSize is set
    When the server sends a message event of exactly that size, or one a byte longer
    Then the first is delivered
    And the second is not delivered: the stream ends, a receive that waits fails, and a line on stderr says why
