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
