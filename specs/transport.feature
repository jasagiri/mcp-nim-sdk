Feature: MCP Transport
  As an MCP developer
  I want to communicate between clients and servers
  So that they can exchange messages securely and reliably

  Scenario: Stdio transport initialization
    Given a new stdio transport instance
    When the transport is started
    Then it should be ready to send and receive messages
    And it should use standard input and output streams

  Scenario: SSE transport initialization
    Given a new SSE transport instance with a valid endpoint
    When the transport is started
    Then it should be ready to send and receive messages
    And it should establish an HTTP connection to the endpoint

  Scenario: Transport sends a message
    Given a transport instance is started
    When a message is sent through the transport
    Then the message should be properly encoded as JSON-RPC
    And the message should be transmitted to the recipient

  Scenario: Transport receives a message
    Given a transport instance is started
    When a JSON-RPC message is received by the transport
    Then the message should be properly decoded
    And the message should be passed to the registered handler

  Scenario: Transport handles connection errors
    Given a transport instance attempts to connect to an unavailable endpoint
    When the transport start method is called
    Then an appropriate error should be thrown
    And the onerror callback should be triggered

  Scenario: Transport handles message sending errors
    Given a transport instance with a broken connection
    When a message is sent through the transport
    Then an appropriate error should be thrown
    And the onerror callback should be triggered

  Scenario: Transport closes cleanly
    Given a transport instance is started
    When the transport is closed
    Then all resources should be released
    And the onclose callback should be triggered
