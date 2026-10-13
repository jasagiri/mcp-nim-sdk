Feature: JSON-RPC errors
  The codes and the messages of the errors the SDK writes.

  @spec:MCP-ERRORS-1
  Scenario: The messages the SDK writes for standard failures are one concise sentence (rule)
    Given a server, an HTTP server or a client that meets a request it cannot serve: an unknown method, params that are missing or of the wrong type, an unknown tool, a body that is not JSON or not a request, or a handler that fails
    When it answers with a JSON-RPC error
    Then the message is on one line, holds no second sentence and is short
    And a handler that fails with a message of its own is told to the peer as "Internal error", without that message

  @spec:MCP-ERRORS-2
  Scenario: A client's error carries the message of its handler and no traceback
    Given a client whose handler for a request of the server fails, by refusing with an error of its own or with any other exception
    When the client answers the server
    Then the message of the JSON-RPC error is the message the handler wrote, on one line, with no trace of where the exception passed
