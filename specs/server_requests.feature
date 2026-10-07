Feature: Requests the server makes of the client
  As a server that needs a model's answer or the user's directories
  I want to ask the client for a sampled message or for its roots
  So that the server works without a model or a file system of its own

  Specification: client/sampling, client/roots and basic/utilities/ping.
  Before 2026-07-28 a server sends requests to a connected client.
  2026-07-28 has no server-initiated requests: a server asks for what it needs
  through the result of the request it is answering.

  @spec:MCP-SERVERREQ-1 @feature:ftSampling
  Scenario: A server asks the client to sample a message
    Given a version before 2026-07-28 and a client that declared sampling
    When the server sends sampling/createMessage
    Then the client gets the request with the server's params, addressed to that client's session
    And the client's result comes back to the server

  @spec:MCP-SERVERREQ-2 @feature:ftRoots
  Scenario: A server asks the client for its roots
    Given a version before 2026-07-28 and a client that declared roots
    When the server sends roots/list
    Then the client's roots come back to the server
    And an answer without a roots array is a remote error

  @spec:MCP-SERVERREQ-3 @feature:ftServerInitiatedRequests
  Scenario: A server pings the client
    Given a version before 2026-07-28 and a connected client
    When the server pings it
    Then the client answers with an empty result and the ping completes

  @spec:MCP-SERVERREQ-4 @feature:ftServerInitiatedRequests
  Scenario: A server asks only for what the client declared and has initialized
    Given a client that declared neither sampling nor roots, or that has not sent initialized
    When the server asks for a message or the roots
    Then the server raises and sends nothing

  @spec:MCP-SERVERREQ-5 @feature:ftServerInitiatedRequests
  Scenario: An error from the client, or silence, ends the server's wait
    Given a server waiting for a client's answer
    When the client answers with an error, or never answers within the timeout
    Then the error carries the client's code, or the wait raises a timeout and the request is cancelled
    And an answer that arrives after the timeout is ignored

  @spec:MCP-SERVERREQ-10 @feature:ftServerInitiatedRequests
  Scenario: A request of the server that belongs to a task may be held until a tasks/result request can carry it
    Given a hold hook that keeps requests of a task and a request of the server that names that task and no request of the client
    When the server sends it, with a time limit or with none
    Then it is not sent until sendHeld puts it on the stream of a tasks/result request, and a request that ran out of time in the meantime is not sent at all
    And a request with no task, or with a request of the client it belongs to, or whose hook declines or is absent, is sent at once
    And a hook that refuses raises to the caller and nothing is sent
    And a request with no time limit waits for the client as long as it takes

  @spec:MCP-SERVERREQ-11 @feature:ftServerInitiatedRequests
  Scenario: What a handler asks of the client belongs to its request, or to its task
    Given a handler of a request that runs as no task, or as a task
    When it asks the client for a ping or for the roots, one ask at a time or several at once
    Then the ask belongs to the request, or to the task and to the tasks/result request waiting on it
    And the task is told it needs input when the first ask goes out and no longer when the last one is answered, by a result or by an error

  @spec:MCP-SERVERREQ-6 @feature:ftServerInitiatedRequests
  Scenario: A wait ends when the client's session or transport ends
    Given a server waiting for a client's answer
    When the client's session ends, or the transport closes or fails
    Then the wait fails, and requests the transport had in flight are cancelled

  @spec:MCP-SERVERREQ-7 @feature:ftServerInitiatedRequests
  Scenario: Answers are matched to their requests
    Given requests to two clients
    When they answer in the other order
    Then each request gets its own answer
    And a response to a request nobody sent is ignored

  @spec:MCP-SERVERREQ-8 @feature:ftServerInitiatedRequests
  Scenario: A handler can ask the client in the middle of a call
    Given a tool handler that asks the client for a message
    When the client calls the tool
    Then the server's request belongs to that call and the client's answer becomes the tool result

  @spec:MCP-SERVERREQ-9 @feature:ftSampling
  Scenario: A 2026-07-28 server sends no request of its own
    Given a 2026-07-28 client
    When the server tries to ask for a message, or a handler asks during a call
    Then it raises, or the call fails, and nothing is sent
    And a client that is sent a request in a 2026-07-28 connection answers method not found

  @spec:MCP-CLIENTREQ-1 @feature:ftSampling
  Scenario: A client answers a sampling request through its handler
    Given a client with a sampling handler
    When the server sends sampling/createMessage
    Then the client declared sampling in initialize, passes the parsed request to the handler and sends its result in wire form
    And a handler that refuses has its error code sent, and one that fails gets an internal error, the client carrying on
    And malformed params are answered with invalid params, also when only a typed field such as the temperature is wrong

  @spec:MCP-CLIENTREQ-2 @feature:ftSampling
  Scenario: A client without a sampling handler does not sample
    Given a client with no sampling handler
    When the server sends sampling/createMessage
    Then the client answers method not found

  @spec:MCP-CLIENTREQ-3 @feature:ftRoots
  Scenario: A client lists its roots when asked
    Given a client with a roots provider
    When the client connects and the server sends roots/list
    Then initialize declares roots with listChanged, and the roots are listed
    And a client that declared no roots answers method not found

  @spec:MCP-CLIENTREQ-4 @feature:ftRootsListChanged
  Scenario: A client says when its roots changed
    Given a client that declared roots with listChanged
    When its roots change and it notifies
    Then notifications/roots/list_changed is sent
    And a client that declared roots without listChanged refuses to notify, and so does a 2026-07-28 connection

  @spec:MCP-CLIENTREQ-5 @feature:ftServerInitiatedRequests
  Scenario: A client answers a server's ping and keeps the type of the request id
    Given a connected client
    When the server pings it, with a string or an integer id
    Then the client answers with an empty result and the same id of the same JSON type

  @spec:MCP-SERVERREQ-12 @feature:ftServerInitiatedRequests
  Scenario: A second answer to the same request is ignored
    Given a request of the server that the client has answered
    When the client answers the same id again
    Then the first answer stands and the server goes on
