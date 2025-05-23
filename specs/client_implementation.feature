Feature: MCP Client Implementation
  As a MCP SDK user
  I want to connect to MCP servers as a client
  So that I can consume resources and tools provided by servers

  Background:
    Given the MCP protocol version is "2024-11-26"
    And a valid message serialization format using JSON-RPC 2.0

  Scenario: Client initialization and connection
    Given I have created an MCP client
    When I connect to an MCP server
    Then the client should perform the protocol handshake correctly
    And negotiate compatible protocol versions
    And exchange capability information
    And establish a functioning connection

  Scenario: Client capability discovery
    Given I have a connected MCP client
    When I query the server's capabilities
    Then the client should discover available capabilities
    And determine which features are supported
    And adapt its behavior to the server's capabilities
    And store the capability information for future reference

  Scenario: Client resource access
    Given I have a connected MCP client
    And the server supports resources
    When I request a list of available resources
    Then the client should receive a list of resources
    And be able to read resource contents
    And handle both text and binary resources correctly
    And properly handle resource templates

  Scenario: Client resource subscription
    Given I have a connected MCP client
    And the server supports resource subscriptions
    When I subscribe to a resource
    Then the client should receive notifications when the resource changes
    And handle resource update notifications correctly
    And be able to unsubscribe from resources
    And clean up subscription resources when disconnected

  Scenario: Client tool invocation
    Given I have a connected MCP client
    And the server supports tools
    When I request a list of available tools
    Then the client should receive a list of tools
    And be able to invoke server tools with parameters
    And receive and interpret tool results correctly
    And handle both success and error results

  Scenario: Client sampling request
    Given I have a connected MCP client
    And the client supports sampling
    When I request sampling from an LLM
    Then the client should format the sampling request correctly
    And send the request to the appropriate LLM
    And return the sampling results to the server
    And handle sampling errors appropriately

  Scenario: Client connection error handling
    Given I have a connected MCP client
    When the connection to the server is interrupted
    Then the client should detect the connection loss
    And attempt to reconnect if configured to do so
    And report appropriate error information
    And maintain state for reconnection if possible

  Scenario: Client message validation
    Given I have a connected MCP client
    When the client receives invalid messages from the server
    Then the client should validate the messages against the protocol
    And reject invalid messages
    And report appropriate validation errors
    And maintain protocol integrity

  Scenario: Client cancellation support
    Given I have a connected MCP client
    And the client has sent a long-running request
    When I request cancellation of the operation
    Then the client should send a cancellation notification
    And handle the cancellation response correctly
    And clean up any resources related to the cancelled operation

  Scenario: Client disconnection and cleanup
    Given I have a connected MCP client
    When I disconnect from the server
    Then the client should send appropriate shutdown messages
    And close all transport connections cleanly
    And release all resources
    And complete any pending operations or report their cancellation
