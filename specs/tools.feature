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

  @spec:MCP-TOOLS-6 @feature:ftTools
  Scenario: A tools method needs the capability and a handler
    Given a server with tool handlers and no tools capability, or the tools capability and no call handler
    When a client sends tools/list or tools/call
    Then the answer is method not found

  # rule
  @spec:MCP-TOOLS-7 @feature:ftTools
  Scenario: Tool names are compared as they are written
    Given tools whose names differ only in letter case, or a name that matches another tool only when case is ignored
    When a client calls them
    Then each call is checked against the schema of the tool of exactly that name, and a name that is not listed is left to the handler

  # rule
  @spec:MCP-TOOLS-8 @feature:ftTools
  Scenario: The tool list keeps the order of the handler on every request
    Given a handler that lists its tools in a fixed order, over one page or several
    When a client lists the tools more than once
    Then each list holds the tools in the order the handler gave them

  # not met
  @spec:MCP-TOOLS-9 @feature:ftTools
  Scenario: A tool is not listed with a null inputSchema
    Given a server whose handler lists a tool whose inputSchema is null, in 2025-11-25 or later
    When a client sends tools/list
    Then the tool is not listed with a null inputSchema: the answer is an internal error, or lists no such tool

  @spec:MCP-TOOLS-10 @feature:ftPerRequestMetadata
  Scenario: A tool whose inputSchema is not an object schema is not listed
    Given a server that lists a tool whose inputSchema has no type object at its root, in 2026-07-28
    When a client lists the tools
    Then the answer is an internal error, the tool being the server's defect
