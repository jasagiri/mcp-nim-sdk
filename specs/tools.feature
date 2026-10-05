Feature: Tools
  As a client of an MCP server
  I want to list the server's tools and call one
  So that a model can act through the server

  @spec:MCP-TOOLS-1 @feature:ftTools
  Scenario: A connected client lists and calls tools
    Given a server with a tool and a connected client
    When the client sends tools/list and tools/call
    Then it receives the tool's definition and the call's result, in the version they settled on

  @spec:MCP-TOOLS-2 @feature:ftTools
  Scenario: A legacy list result carries no 2026-07-28 field
    Given an initialized legacy client
    When it lists tools
    Then the result has no resultType and no cache field

  @spec:MCP-TOOLS-3 @feature:ftTools
  Scenario: A server checks the arguments of a call against the tool's inputSchema
    Given a server that lists a tool with an inputSchema
    When the tool is called with arguments that fit, the handler runs
    And when the arguments break the schema, or required ones are missing because none were sent, the handler does not run and the answer names the argument at fault
    And a tool listed without an inputSchema, or not listed, is left to its handler

  @spec:MCP-TOOLS-4 @feature:ftToolInputErrors
  Scenario: Invalid input is a protocol error before 2025-11-25 and a tool result from it
    Given a call whose arguments break the tool's inputSchema
    When it is answered in a version before 2025-11-25, the answer is invalid params
    And from 2025-11-25 the answer is a tool result with isError and a text the model can act on

  @spec:MCP-TOOLS-5 @feature:ftTools
  Scenario: An inputSchema that cannot be checked passes nothing as valid
    Given a tool whose inputSchema names a dialect or uses a keyword the server cannot check
    When the tool is called
    Then the answer is an internal error and the handler does not run

