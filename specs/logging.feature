Feature: Logging
  As an operator watching a server through its client
  I want the server's log messages at a level I chose
  So that I see what matters without being flooded

  Specification: server/utilities/logging. Before 2026-07-28 a client sets one
  level for its session with logging/setLevel. 2026-07-28 removed that
  request: a client asks for logs per request in the _meta field
  io.modelcontextprotocol/logLevel, and a server sends none otherwise.

  @spec:MCP-LOGGING-1 @feature:ftLogging
  Scenario: A server's log messages reach a client as notifications
    Given a version before 2026-07-28 and a client that never set a level
    When a handler logs at every level
    Then the client gets a notifications/message for each, carrying level, logger and data
    And the message belongs to the request that logged it

  @spec:MCP-LOGGING-2 @feature:ftLoggingSetLevel
  Scenario: setLevel filters what a session receives
    Given a server that declared the logging capability
    When a client sends logging/setLevel with warning and a handler logs at every level
    Then the client gets warning and above
    And another client with its own level gets what its level allows

  @spec:MCP-LOGGING-3 @feature:ftLoggingSetLevel
  Scenario: setLevel needs a known level, the capability and an initialized session
    Given a version before 2026-07-28
    When a client sends logging/setLevel with an unknown level, to a server without the logging capability, or before it has initialized
    Then the answers are invalid params, method not found and invalid request in that order

  @spec:MCP-LOGGING-4 @feature:ftLogging
  Scenario: A server logs only what it declared and only to sessions that exist
    Given a server that did not declare the logging capability
    When a handler logs
    Then it is an internal error and nothing is sent
    And a client that ended its session is sent nothing

  @spec:MCP-LOGGING-5 @feature:ftLogging
  Scenario: 2026-07-28 sends no log messages to a request without a log level
    Given a 2026-07-28 server
    When a handler logs during a request whose _meta has no logLevel, or outside any request
    Then no notification is sent

  @spec:MCP-LOGGING-6 @feature:ftLogging
  Scenario: 2026-07-28 sends log messages at or above the level of the request that asked, to that request only
    Given a 2026-07-28 request whose _meta names a logLevel
    When a handler logs at every level
    Then the client gets the messages at that level and above
    And another request without a level is told nothing

  @spec:MCP-LOGGING-7 @feature:ftLogging
  Scenario: 2026-07-28 refuses a log level that is not one
    Given a 2026-07-28 server
    When a request names a logLevel that is not a log level
    Then the answer is invalid params

  @spec:MCP-LOGGING-8 @feature:ftLogging
  Scenario: logging/setLevel does not exist in 2026-07-28
    Given a 2026-07-28 connection
    When a client sends logging/setLevel
    Then the answer is method not found
    And the client refuses to send it

  @spec:MCP-LOGGING-9 @feature:ftLogging
  Scenario: A client sets a level and receives messages
    Given a server that declared logging
    When the client sets the level and the server logs
    Then logging/setLevel carries the level and the client's callback gets level, logger and data
    And the client refuses to set a level on a server without the logging capability
