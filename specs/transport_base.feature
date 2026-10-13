Feature: What every transport shares
  As someone who writes a transport for the SDK
  I want the defaults of the base and the classification of messages to be fixed
  So that a transport with one peer needs only the plain sends

  Specification: JSON-RPC 2.0, "Request object", "Response object" and
  "Notification": a request carries an id and a method, a notification a
  method and no id, a response an id and a result or an error. The route of a
  send is the SDK's own (Streamable HTTP uses it to pick a stream).

  @spec:MCP-TRANSPORT-1
  Scenario: A transport that ignores routes receives a routed send as a plain send
    Given a transport that implements only the sends without a route
    When the server sends a request or a notification naming a route
    Then the plain send is called with it

  @spec:MCP-TRANSPORT-2
  Scenario: A message is a request, a notification or a response by its members
    Given a JSON-RPC message
    When it is classified
    Then an object with an id and a method is a request, one with a method and no id is a notification, one with an id and a result or an error is a response, and anything else, including a value that is not an object, is none of them

  @spec:MCP-TRANSPORT-3
  Scenario: A response carries a result or an error, and one with neither is not sent as a success
    Given a response with a result, one with an error, and one with neither (a handler that returned a default response)
    When it is encoded for the wire
    Then the first carries its result, even an empty object, and the second its error
    And the third is sent as the internal error -32603 with the message "Internal error" and no data, and one line on stderr says that the response had neither

  @spec:MCP-TRANSPORT-4
  Scenario: Every request the SDK sends carries a string id that is not null
    Given a client or a server that sends requests, in any version
    When a request leaves, whichever the method
    Then its id is a string, never null and never empty

  @spec:MCP-TRANSPORT-5
  Scenario: The SDK does not use a request id twice
    Given a client that makes requests, some answered and some given up after a timeout, or a server that sends several requests to one client
    When the requests are sent
    Then no id is used by two of them

  @spec:MCP-TRANSPORT-6
  Scenario: An error response states an integer code and a message, and no result
    Given a server whose requests fail in different ways: an unknown method, invalid params, an unknown tool, a handler's own error with data, a defect of a handler
    When the server answers, in any version
    Then each answer has an error with an integer code and a string message and has no result
    And a handler's own code, message and data arrive as it gave them
    And a defect of a handler answers the internal error without the cause in the message
    And an unknown method answers method not found

  @spec:MCP-TRANSPORT-7
  Scenario: A result may be an object of any shape
    Given a handler of a method of the server's own whose result is an object with members of any JSON type
    When a client of any version asks for it
    Then every member arrives with the value the handler gave

  @spec:MCP-TRANSPORT-8
  Scenario: A response on the wire states a result or an error, never both
    Given a response that holds both a result and an error, one with a result and one with an error
    When each is encoded for the wire
    Then the first carries the error alone, the second the result alone and the third the error alone, whose code is an integer

  @spec:MCP-TRANSPORT-9
  Scenario: A notification the SDK sends carries no id
    Given a client that connects and gives up a request, and a server that reports progress and a list change
    When they send notifications, in any version
    Then no notification has an id

  @spec:MCP-TRANSPORT-10
  Scenario: A reserved _meta key that the SDK does not define is carried as it is
    Given a request whose _meta holds keys under a prefix MCP reserves, with a value of any JSON type, null among them
    When a client sends it, or a server serves it, in any version
    Then the keys go out with the values they had, the server answers normally, and the handler sees every key as it was sent

  @spec:MCP-TRANSPORT-11 @feature:ftPerRequestMetadata
  Scenario: A client takes the codes of the legacy range as the peer's own
    Given a server that answers a request with an error whose code is -32000, -32001, -32002, -32010 or -32019
    When the client reads the answer, in any version
    Then it raises the peer's error with that code and that message, stays connected and its next request works

  @spec:MCP-TRANSPORT-12 @feature:ftPerRequestMetadata
  Scenario: A 2026-07-28 server emits only the codes the specification defines
    Given a 2026-07-28 server and requests that fail: an unknown or removed method, missing or wrong params, an unknown tool, a defect of a handler, an unknown resource or prompt, missing client capabilities, an unknown version
    When it answers
    Then every code is one of -32700, -32600 to -32603 or -32020 to -32022
    And an unknown resource is -32602, not -32002

  @spec:MCP-TRANSPORT-13
  Scenario: A failure local to the SDK is not given the shape of a peer's error
    Given a request that times out and a connection that is closed
    When the client reports them
    Then each is a local error of its own kind and neither is the error a client raises for a peer's JSON-RPC error
