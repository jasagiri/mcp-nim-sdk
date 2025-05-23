Feature: MCP Protocol
  As an MCP client or server developer
  I want to use a standardized protocol interface
  So that I can reliably communicate between clients and servers

  Background:
    Given the MCP protocol is initialized

  Scenario: Protocol initialization
    When a client initializes a connection with a server
    Then the client should send an initialize request with protocol version and capabilities
    And the server should respond with its protocol version and capabilities
    And the client should send an initialized notification as acknowledgment
    And the connection should be ready for message exchange

  Scenario: Sending a request from client to server
    When a client sends a request to a server
    Then the server should receive the request
    And the server should send a response back to the client
    And the client should receive the response

  Scenario: Sending a notification from client to server
    When a client sends a notification to a server
    Then the server should receive the notification
    And the server should not send a response

  Scenario: Handling a request with invalid parameters
    When a client sends a request with invalid parameters
    Then the server should respond with an error
    And the error code should indicate invalid parameters

  Scenario: Handling a non-existent method
    When a client sends a request for a non-existent method
    Then the server should respond with an error
    And the error code should indicate method not found

  Scenario: Handling connection termination
    When either party terminates the connection
    Then the connection should be closed
    And resources should be properly cleaned up
