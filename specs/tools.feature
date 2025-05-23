Feature: MCP Tools
  As an MCP server developer
  I want to expose executable functionality to clients
  So that LLMs can perform actions through my server

  Scenario: Registering a simple tool
    Given a server has been initialized
    When a tool is registered with name "add_numbers"
    And the tool has an input schema for numbers "a" and "b"
    Then the tool should appear in the tools list
    And the tool should have the specified name "add_numbers"
    And the tool should have the defined input schema

  Scenario: Calling a simple tool with valid parameters
    Given a server has a tool named "add_numbers"
    When a client calls the tool with parameters {"a": 5, "b": 3}
    Then the server should execute the tool with the provided parameters
    And the server should return the result 8 to the client

  Scenario: Calling a tool with invalid parameters
    Given a server has a tool named "add_numbers"
    When a client calls the tool with parameters {"a": "not a number", "b": 3}
    Then the server should return an error response
    And the error should indicate invalid parameters

  Scenario: Tool with progress reporting
    Given a server has a tool named "long_operation"
    And the tool supports progress reporting
    When a client calls the tool
    Then the server should send progress updates during execution
    And the client should receive the progress updates
    And the server should return the final result when complete

  Scenario: Tool error handling
    Given a server has a tool named "might_fail"
    When a client calls the tool and it encounters an error
    Then the server should return an error result
    And the error result should include an error message
    And the client should receive the error result

  Scenario: Tool with custom return type
    Given a server has a tool named "get_data"
    And the tool returns a custom data structure
    When a client calls the tool
    Then the server should return the custom data structure
    And the client should be able to parse the result
