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
