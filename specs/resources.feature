Feature: MCP Resources
  As an MCP server developer
  I want to expose data and content to clients
  So that they can be accessed by LLMs for context

  Scenario: Registering a text resource
    Given a server has been initialized
    When a text resource is registered with URI "example://text"
    Then the resource should appear in the resource list
    And the resource should have the specified URI "example://text"
    And the resource should have the mime type "text/plain"

  Scenario: Registering a binary resource
    Given a server has been initialized
    When a binary resource is registered with URI "example://binary"
    Then the resource should appear in the resource list
    And the resource should have the specified URI "example://binary"
    And the resource should have a mime type

  Scenario: Registering a resource template
    Given a server has been initialized
    When a resource template is registered with pattern "example://{id}"
    Then the template should appear in the resource templates list
    And the template should have the specified pattern "example://{id}"

  Scenario: Reading a text resource
    Given a server has a text resource with URI "example://text"
    When a client requests to read the resource
    Then the server should return the resource content
    And the content should include the text data
    And the content should have the correct mime type

  Scenario: Reading a binary resource
    Given a server has a binary resource with URI "example://binary"
    When a client requests to read the resource
    Then the server should return the resource content
    And the content should include the base64-encoded binary data
    And the content should have the correct mime type

  Scenario: Resource update notification
    Given a server has a resource with URI "example://updatable"
    And a client has subscribed to updates for the resource
    When the resource content changes
    Then the server should send a resource updated notification
    And the notification should include the resource URI
