Feature: MCP Tool Management
  As a MCP Server implementer
  I want to register and execute tools
  So that clients can perform actions through the server

  Background:
    Given the MCP protocol version is "2024-11-26"
    And a valid message serialization format using JSON-RPC 2.0
    And I have a running MCP server with tool capabilities
      | listChanged | progressReporting |
      | true        | true              |

  Scenario: Registering a simple tool
    When I register a tool with the following properties
      | name   | description       | inputSchema                                                                           |
      | "echo" | "Echo back input" | {"type": "object", "properties": {"message": {"type": "string"}}, "required": ["message"]} |
    Then the tool should be available in the tool list via "tools/list"
    And the tool definition should include the correct name, description, and schema
    And the client should be able to call the tool via "tools/call"

  Scenario: Tool with rich input schema
    When I register a tool with a rich input schema
      """json
      {
        "type": "object",
        "properties": {
          "query": {
            "type": "string",
            "description": "The search query to execute"
          },
          "maxResults": {
            "type": "integer",
            "description": "Maximum number of results to return",
            "default": 10
          },
          "filters": {
            "type": "object",
            "properties": {
              "category": {"type": "string"},
              "minRating": {"type": "number", "minimum": 0, "maximum": 5},
              "tags": {"type": "array", "items": {"type": "string"}}
            }
          },
          "sortBy": {
            "type": "string",
            "enum": ["relevance", "date", "rating"],
            "default": "relevance"
          }
        },
        "required": ["query"]
      }
      """
    Then the tool schema should be correctly registered
    And parameter validation should enforce the schema constraints
    And default values should be applied when parameters are omitted

  Scenario: Tool success response with different content types
    Given I have registered a tool that returns various content types
    When a client calls the tool with the following request
      | contentType | format     |
      | "text"      | "plain"    |
      | "json"      | "nested"   |
      | "html"      | "table"    |
      | "markdown"  | "document" |
      | "image"     | "png"      |
    Then the server should return a success response
    And the response should have "isError" set to false
    And each content item should have the correct type and format
    And binary content should be properly encoded in base64

  Scenario: Tool error response with details
    Given I have registered a tool that returns detailed errors
    When a client calls the tool with parameters that trigger an error
    Then the server should return an error response
    And the response should have "isError" set to true
    And the error details should include:
      | field       | value                    |
      | "code"      | A specific error code    |
      | "message"   | A descriptive message    |
      | "details"   | Additional error context |
    And the client should be able to handle the error gracefully

  Scenario: Progress reporting for long-running tools
    Given I have registered a long-running tool with progress reporting
    When a client calls the tool with parameters
      | executionTime | reportInterval | progressType  |
      | 10 seconds    | 1 second       | "percentage"  |
    Then the server should start executing the tool
    And send progress notifications at regular intervals
    And the progress notifications should include:
      | field         | description                     |
      | "token"       | Identifies the request          |
      | "percentage"  | Current progress (0-100)        |
      | "message"     | Optional status message         |
    And finally return the complete result when finished

  Scenario: Tool execution with progress reporting by work units
    Given I have registered a tool that processes items in batches
    When a client calls the tool with a workload of "1000" items
    Then the server should report progress by work units
    And the progress notifications should include:
      | field        | description                   |
      | "workDone"   | Number of items processed     |
      | "workTotal"  | Total number of items         |
    And the progress should update incrementally

  Scenario: Cancellable tool execution
    Given I have registered a cancellable long-running tool
    When a client calls the tool with parameters for a "30" second operation
    And the client sends a cancellation request after "5" seconds
    Then the server should stop the tool execution
    And release any resources held by the tool
    And return a cancellation response
    And include information about the partial progress made

  Scenario: Concurrent tool executions
    Given I have registered a tool that supports concurrent execution
    When multiple clients call the tool simultaneously
      | clientId | parameters            |
      | "c1"     | {"duration": 5}       |
      | "c2"     | {"duration": 3}       |
      | "c3"     | {"duration": 7}       |
    Then the server should handle all requests concurrently
    And each client should receive the correct response
    And tool executions should not interfere with each other
    And server resources should be properly managed

  Scenario: Tool with input validation and error handling
    Given I have registered a tool with strict input validation
    When a client calls the tool with invalid inputs
      | paramName    | value     | validationRule              | expectedError                 |
      | "email"      | "invalid" | "email format"              | "Invalid email format"        |
      | "age"        | -5        | "positive integer"          | "Age must be positive"        |
      | "password"   | "short"   | "minimum length 8"          | "Password too short"          |
      | "selections" | []        | "non-empty array"           | "Must select at least one"    |
    Then each validation error should be properly reported
    And the error messages should be clear and actionable
    And no partial execution should occur for invalid inputs

  Scenario: Tool with state
    Given I have registered a stateful tool
    When a client performs the following sequence of operations
      | operation | parameters            | expectedState       |
      | "init"    | {"id": "session-123"} | "initialized"       |
      | "update"  | {"value": 42}         | "value-updated"     |
      | "process" | {"action": "run"}     | "processing"        |
      | "finish"  | {}                    | "completed"         |
    Then each operation should correctly update the tool state
    And the results should reflect the current state
    And the state should persist between calls within the session

  Scenario: Tool registry management
    Given I have a tool registry with multiple tools
    When I perform management operations
      | operation    | toolName     |
      | "disable"    | "sensitive"  |
      | "update"     | "calculator" |
      | "remove"     | "deprecated" |
    Then the tool list should reflect these changes
    And clients should be notified of changes via "notifications/tools/list_changed"
    And disabled tools should not be callable
    And removed tools should not appear in listings

  Scenario: Tool execution metrics and logging
    Given I have tools with execution metrics enabled
    When clients call various tools multiple times
    Then the server should collect metrics including:
      | metric              | description                        |
      | "callCount"         | Number of times tool was called    |
      | "avgExecutionTime"  | Average execution time             |
      | "errorRate"         | Percentage of calls with errors    |
      | "lastCalled"        | Timestamp of last invocation       |
    And tool execution should be properly logged
    And logs should include call parameters and results
    And sensitive information should be redacted from logs