Feature: MCP Client
  As a developer building an MCP client application
  I want to establish connections with MCP servers
  So that I can access their resources and tools

  Background:
    Given the MCP client is initialized with name "test-client" and version "1.0.0"

  Scenario: Client successfully connects to a server
    Given a server is available at the specified transport
    When the client connects to the server
    Then the connection should be established
    And the client should receive the server's capabilities

  Scenario: Client lists available resources
    Given the client is connected to a server
    When the client requests a list of resources
    Then the client should receive a list of resources
    And each resource should have a URI and name

  Scenario: Client reads a resource
    Given the client is connected to a server
    And the server has a resource with URI "example://resource"
    When the client requests to read the resource
    Then the client should receive the resource content
    And the content should include the resource URI and data

  Scenario: Client calls a tool
    Given the client is connected to a server
    And the server has a tool named "example_tool"
    When the client calls the tool with valid parameters
    Then the client should receive the tool's result
    And the result should match the expected output
