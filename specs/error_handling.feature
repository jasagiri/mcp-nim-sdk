Feature: MCP Error Handling
  As a MCP Server implementer
  I want robust error handling mechanisms
  So that I can handle failures gracefully and provide useful error information

  Scenario: Handle JSON-RPC parse errors
    Given I have a running MCP server
    When the server receives malformed JSON
      | message                |
      | "{invalid json syntax" |
    Then the server should return a parse error response
      | errorCode | errorMessage  |
      | -32700    | "Parse error" |
    And the error should be logged appropriately

  Scenario: Handle invalid request errors
    Given I have a running MCP server
    When the server receives a request with missing required fields
      | missing    |
      | "method"   |
      | "jsonrpc"  |
    Then the server should return an invalid request error
      | errorCode | errorMessage      |
      | -32600    | "Invalid request" |
    And the error should be logged appropriately

  Scenario: Handle method not found errors
    Given I have a running MCP server
    When the server receives a request for an unknown method
      | method            |
      | "unknown/method"  |
    Then the server should return a method not found error
      | errorCode | errorMessage        |
      | -32601    | "Method not found"  |
    And the error should be logged appropriately

  Scenario: Handle invalid parameters errors
    Given I have a running MCP server
    When the server receives a request with invalid parameters
      | method      | parameters                   |
      | "tools/call" | {"name": "tool", "arguments": 123} |
    Then the server should return an invalid parameters error
      | errorCode | errorMessage         |
      | -32602    | "Invalid parameters" |
    And the error should include details about the invalid parameters

  Scenario: Handle internal server errors
    Given I have a running MCP server with a handler that throws exceptions
    When the server processes a request that causes an internal error
    Then the server should return an internal error response
      | errorCode | errorMessage         |
      | -32603    | "Internal error"     |
    And the server should not crash
    And detailed error information should be logged

  Scenario: Handle server not initialized errors
    Given I have a running MCP server that has not been initialized
    When a client sends a request that requires initialization
      | method            |
      | "resources/list"  |
    Then the server should return a server not initialized error
      | errorCode | errorMessage              |
      | -32002    | "Server not initialized"  |
    And the error should inform the client to initialize first

  Scenario: Handle request cancellation errors
    Given I have a running MCP server processing a long-running request
    When the client cancels the request
    Then the server should stop processing the request
    And return a request cancelled error
      | errorCode | errorMessage          |
      | -32800    | "Request cancelled"   |
    And clean up any resources allocated for the request

  Scenario: Handle content too large errors
    Given I have a running MCP server with size limits
    When a client sends a request with content exceeding the limits
    Then the server should return a content too large error
      | errorCode | errorMessage         |
      | -32801    | "Content too large"  |
    And the error should include information about size limits

  Scenario: Handle resource not found errors
    Given I have a running MCP server with resource capabilities
    When a client requests a non-existent resource
      | uri                       |
      | "file:///nonexistent.txt" |
    Then the server should return a resource not found error
      | errorCode | errorMessage          |
      | -32802    | "Resource not found"  |
    And the error should include the requested URI

  Scenario: Error with additional context
    Given I have a running MCP server
    When a client request causes an error with additional context
    Then the server should return an error with data field
    And the data field should contain the additional context
    And the additional context should help diagnose the issue
