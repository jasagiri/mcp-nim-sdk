Feature: Event streams over Streamable HTTP
  As someone whose server sends more than one message to answer a request
  I want the answer to be an event stream a client can resume, and a stream for what the server says on its own
  So that long work and server messages reach the client over plain HTTP

  Specification: basic/transports, Streamable HTTP, in the versions that have
  each rule. A POST may be answered by an event stream (2025-03-26 on). A GET
  stream carries what the server says outside a request, and event ids let a
  client resume (2025-03-26 to 2025-11-25). 2025-11-25 added the priming event
  and polling. 2025-03-26 alone accepts JSON-RPC batches. 2026-07-28 has none
  of the GET stream, the resumption and the batches.

  @spec:MCP-HTTPSTREAM-1 @feature:ftStreamableHttp
  Scenario: A request that produced messages of its own is answered by an event stream
    Given a Streamable HTTP server
    When a request is posted during which the server sent notifications
    Then the answer is an event stream with the notifications first and the response last
    And a request during which the server sent nothing is answered by a plain JSON body

  @spec:MCP-HTTPSTREAM-2 @feature:ftStreamableHttp
  Scenario: Each stream carries the messages of its own request
    Given two requests at once on one session
    When each of them makes the server send notifications
    Then each stream carries only its own
    And a notification for a request that is not in progress cannot be sent on it

  @spec:MCP-HTTPSTREAM-3 @feature:ftStreamableHttp
  Scenario: An event stream says it is not to be cached or buffered
    Given an event stream
    When its head is read
    Then it carries the security headers, forbids caching and tells proxies not to buffer

  @spec:MCP-HTTPSTREAM-4 @feature:ftHttpResumability
  Scenario: Every event has an id that tells it apart
    Given an event stream from 2025-03-26 to 2025-11-25
    When its events are read
    Then every event has an id and the ids differ

  @spec:MCP-HTTPSTREAM-5 @feature:ftSsePolling
  Scenario: From 2025-11-25 a stream opens with a priming event
    Given a version from 2025-11-25 to before 2026-07-28
    When a stream opens
    Then its first event has an id and no data
    And in 2025-03-26 and 2025-06-18 its first event is a message

  @spec:MCP-HTTPSTREAM-6 @feature:ftStreamableHttp
  Scenario: 2026-07-28 streams are not primed
    Given a Streamable HTTP request of 2026-07-28
    When its stream's events are read
    Then there is no priming event

  @spec:MCP-HTTPSTREAM-7 @feature:ftHttpResumability
  Scenario: A client resumes a stream with Last-Event-ID and gets what follows
    Given a stream cut after its first event
    When the client sends GET with Last-Event-ID naming that event
    Then it gets the rest and not the first again
    And a stream of another session is not replayed

  @spec:MCP-HTTPSTREAM-8 @feature:ftHttpResumability
  Scenario: A Last-Event-ID the server cannot honour is refused
    Given a server
    When the Last-Event-ID names no stream the server knows, is not an event id, or names an event the server forgot
    Then the answer is 400

  @spec:MCP-HTTPSTREAM-9 @feature:ftHttpResumability
  Scenario: A client resumes a stream that was cut before the response
    Given a client that saw an event id on a stream cut before the response
    When the cut happens
    Then the client asks for the events after that id and receives the response
    And it stops when the server answers the resumption with 404, or after as many resumptions as it may make
    And it does not resume without an event id, or in a version without resumption, but reports the stream closed

  @spec:MCP-HTTPSTREAM-10 @feature:ftSsePolling
  Scenario: A client waits as long as the server's retry asks
    Given a server that closed a stream and asked for a delay with retry
    When the client resumes
    Then it waits at least that long

  @spec:MCP-HTTPSTREAM-11 @feature:ftHttpResumability
  Scenario: An event with an id and no data is not a message
    Given a stream with an event that has an id and no data
    When the client receives it
    Then it is neither a message nor an error

  @spec:MCP-HTTPGET-1 @feature:ftHttpGetStream
  Scenario: A client opens a GET stream and hears the server's own messages
    Given a session from 2025-03-26 to 2025-11-25
    When the client opens GET on the endpoint
    Then the server's notifications arrive on it, once for each listening session
    And a notification sent before the client opened GET is waiting for it
    And a request the server sends on it is answered by the client with POST

  @spec:MCP-HTTPGET-2 @feature:ftHttpGetStream
  Scenario: A session has one GET stream
    Given a session with a GET stream open
    When the client opens a second one
    Then the second takes the stream over

  @spec:MCP-HTTPGET-3 @feature:ftHttpGetStream
  Scenario: A GET the server cannot serve is refused
    Given a server
    When GET has no session id, names an unknown session, does not accept an event stream, or comes from a foreign Origin
    Then the answers are 400, 404, 406 and 403 in that order

  @spec:MCP-HTTPGET-4 @feature:ftHttpGetStream
  Scenario: The GET stream ends with its session
    Given a GET stream open on a session
    When the client sends DELETE, or the session expires
    Then the stream ends

  @spec:MCP-HTTPGET-5 @feature:ftStreamableHttp
  Scenario: 2026-07-28 has no GET stream and no request of the server
    Given a 2026-07-28 endpoint
    When GET is sent
    Then no stream opens: the answer is 400 or 405
    And the server cannot send a request of its own on a request's stream

  @spec:MCP-HTTPGET-g2f-hs-b-1 @feature:ftStreamableHttp
  Scenario: A session negotiated at 2024-11-05 has no GET stream
    Given a session that initialized at 2024-11-05 over the Streamable HTTP endpoint
    When it sends GET
    Then the answer is 405 and Allow names POST and DELETE

  @spec:MCP-HTTPGET-6 @feature:ftHttpGetStream
  Scenario: A client listens on the GET stream
    Given an initialized session from 2025-03-26 to 2025-11-25
    When the server says something outside any request
    Then the client receives it, and a request the server sends there is answered
    And if the GET stream is cut the client reconnects naming the last event id it saw

  @spec:MCP-HTTPGET-7 @feature:ftHttpGetStream
  Scenario: A client does not open a GET stream it cannot have
    Given a server that answers GET with 405, a version without the GET stream, or a client told not to listen
    When the session is initialized
    Then the client asks once or not at all

  @spec:MCP-HTTPSESSION-1 @feature:ftHttpSessions
  Scenario: A client ends its session
    Given a session
    When the client closes
    Then it sends DELETE with the session id and the server forgets the session
    And a server that refuses DELETE with 405 does not make closing fail
    And a client without a session sends no DELETE
    And an open GET stream ends with the client

  @spec:MCP-HTTPSESSION-2 @feature:ftHttpSessions
  Scenario: A server may end a session that is idle
    Given a session unused for longer than the server's limit
    When idle sessions are expired
    Then it is gone and the server is told
    And a session in use, or one with a GET stream open, stays
    And when the session limit is reached by idle sessions one is dropped to make room

  @spec:MCP-HTTPVER-1 @feature:ftProtocolVersionHeader
  Scenario: The MCP-Protocol-Version header names a version the server speaks
    Given a session of 2025-06-18 to 2025-11-25
    When a request carries the header naming the negotiated version
    Then it is served
    And a header naming a version nobody released, not a version, or a released version the server does not serve is 400, for a notification as for a request
    And a request without the header is served as the earlier version

  @spec:MCP-HTTPBATCH-1 @feature:ftJsonRpcBatch
  Scenario: A 2025-03-26 server answers a batch
    Given a session of 2025-03-26
    When a batch of requests is posted
    Then the answer is an array with a response for each
    And in a batch of requests and notifications only the requests are answered
    And a batch of notifications only, or of responses only, is answered 202 with no body
    And a batch whose requests make the server send notifications is answered by a stream with one response per request

  @spec:MCP-HTTPBATCH-2 @feature:ftJsonRpcBatch
  Scenario: A batch that is not valid is refused
    Given a session of 2025-03-26
    When the batch holds initialize, is empty, or holds something that is not an object
    Then the answer is 400

  @spec:MCP-HTTPBATCH-3 @feature:ftStreamableHttp
  Scenario: 2025-06-18 removed batches
    Given a session of 2025-06-18
    When a batch is posted
    Then the answer is 400

  @spec:MCP-HTTPCLIENT-1 @feature:ftStreamableHttp
  Scenario: A client says it accepts both a JSON body and an event stream
    Given a client of a Streamable HTTP server
    When it posts a message
    Then the Accept header lists both application/json and text/event-stream
    And the GET that opens a stream lists text/event-stream

  @spec:MCP-HTTPSTREAM-g2f-hs-a-1
  Scenario: The server transport says whether it is accepting, stops accepting on close, and hands over what a peer posted
    Given a transport that has not been started
    Then it is not accepting; listening starts it and close stops it and frees its port
    And a request a peer posted is handed to the server by receive and by receiveMessage

  @spec:MCP-HTTPSTREAM-g2f-hs-a-2
  Scenario: Sessions end when asked, expire only when a timeout is set, and make room when idle
    Given a session with a response stream open
    When the session ends
    Then the stream ends
    And a timeout of 0 keeps sessions until DELETE
    And at the session limit a session that was used but went idle is dropped to make room for a new client
    And 0 sessions per address means no limit

  @spec:MCP-HTTPSTREAM-g2f-hs-a-3
  Scenario: The limits on queued messages and stored streams are exact
    Given a limit of N queued messages
    Then N messages are taken and the next is refused with 503
    And a session that may keep N finished streams keeps N and forgets the oldest finished one when it would hold more

  @spec:MCP-HTTPSTREAM-g2f-hs-a-4
  Scenario: A cancellation names only the sender's own request, and a notification's subscription id is rewritten only for its own stream
    Given requests in progress from two sessions that chose the same ids
    When one session cancels by the id it chose
    Then the server is told to cancel that session's own request
    And a 2026-07-28 request is not cancelled by a notification that names its id without a session
    And a notification on a subscription stream that names another subscription keeps that id
    And a notification whose params is not an object arrives as it was sent

  @spec:MCP-HTTPSTREAM-g2f-hs-a-5
  Scenario: Empty answers carry no Content-Type, and a session whose initialize answer names no version is held to the newest legacy version
    Given an initialized session
    When a notification is posted on it
    Then the 202 answer has no Content-Type header
    And an initialize answer that names no version gives a session that refuses a version header the build does not speak

  @spec:MCP-HTTPSTREAM-g2f-hs-a-6
  Scenario: A transport is made only for a version the build speaks
    Given a version outside the range the build speaks
    When a transport is made for it
    Then ValueError is raised

  @spec:MCP-HTTPSTREAM-g2f-hs-a-7
  Scenario: The Host header is judged as the sender wrote it
    Given a transport bound to loopback
    Then a Host that is the bare IPv6 loopback address is served
    And a request with no Host header is answered 403
