Feature: MCP Resource Management
  As a MCP Server implementer
  I want to register and manage resources
  So that clients can discover and access server-provided data

  Background:
    Given I have a running MCP server with resource capabilities
      | subscribe | listChanged |
      | true      | true        |

  Scenario: Registering a static text resource
    When I register a text resource with the following properties
      | uri                   | name              | description         | mimeType     |
      | "file:///example.txt" | "Example Text File" | "A text file example" | "text/plain" |
    Then the resource should be available in the resource list
    And the client should be able to read the resource content via "resources/read"
    And the resource content should have the correct text content
    And the resource content should have the correct MIME type

  Scenario: Registering a binary resource
    When I register a binary resource with the following properties
      | uri                   | name                | description          | mimeType                |
      | "file:///example.bin" | "Example Binary File" | "A binary file example" | "application/octet-stream" |
    Then the resource should be available in the resource list
    And the client should be able to read the resource content via "resources/read"
    And the resource content should have the correct binary content in base64 encoding
    And the resource content should have the correct MIME type

  Scenario: Registering multiple resources
    When I register multiple resources with different URIs
    Then all resources should be available in the resource list
    And each resource should be independently accessible
    And the resources should be returned with the correct metadata

  Scenario: Registering a resource template
    When I register a resource template with the following properties
      | uriTemplate           | name           | description       | mimeType     |
      | "file:///docs/{name}.txt" | "Document File" | "A text document" | "text/plain" |
    Then the template should be available in the resource templates list
    And the client should be able to read resources matching the template

  Scenario: Resource subscription and updates
    Given I have registered a resource with update capability
    When a client subscribes to the resource via "resources/subscribe"
    And the resource content changes
    Then the server should send a "notifications/resources/updated" notification
    And the client should be able to read the updated content

  Scenario: Resource list change notifications
    Given I have registered several resources
    When I add a new resource to the registry
    Then the server should send a "notifications/resources/list_changed" notification
    And the updated resource list should include the new resource

  Scenario: Resource URI validation
    When I attempt to register a resource with an invalid URI
    Then the registration should fail with an appropriate error
    And the invalid resource should not appear in the resource list

  Scenario: Reading non-existent resources
    When a client attempts to read a resource that doesn't exist
    Then the server should respond with a "ResourceNotFound" error
