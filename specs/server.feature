Feature: MCP Server
  As a developer building an MCP server
  I want to expose resources and tools to MCP clients
  So that they can access and interact with my data and functionality

  Background:
    Given the MCP server is initialized with name "test-server" and version "1.0.0"

  Scenario: Server initialization
    When the server is initialized
    Then it should be ready to accept connections
    And it should have an empty list of resources and tools

  Scenario: Server registers a resource
    Given the server is initialized
    When the server registers a resource with URI "example://resource"
    Then the resource should be available for clients to discover
    And the resource URI should be "example://resource"

  Scenario: Server handles a resource request
    Given the server is initialized
    And the server has registered a resource with URI "example://resource"
    When a client requests to read the resource
    Then the server should return the resource content
    And the content should include the resource URI and data

  Scenario: Server registers a tool
    Given the server is initialized
    When the server registers a tool named "example_tool"
    Then the tool should be available for clients to discover
    And the tool should have an input schema

  Scenario: Server handles a tool call
    Given the server is initialized
    And the server has registered a tool named "example_tool"
    When a client calls the tool with valid parameters
    Then the server should execute the tool
    And the server should return the tool's result to the client
