Feature: MCP Roots Management
  As a MCP server implementer
  I want to register and manage roots
  So that clients can access hierarchical resource structures

  Background:
    Given I have a running MCP server with roots capabilities
      | listChanged |
      | true        |

  Scenario: Registering a root
    When I register a root with the following properties
      | uri                | name            |
      | "file:///home/user" | "User Directory" |
    Then the root should be available in the root list
    And clients should be able to query the root via "roots/list"
    And the root should have the correct URI and name

  Scenario: Registering multiple roots
    When I register multiple roots with different URIs
      | uri                    | name                |
      | "file:///home/user"     | "User Directory"     |
      | "file:///etc"           | "Configuration Files" |
      | "db://localhost/mydb"   | "Database"           |
    Then all roots should be available in the root list
    And each root should be independently accessible
    And the roots should be returned with the correct metadata

  Scenario: Root list change notifications
    Given I have registered several roots
    When I add a new root to the registry
    Then the server should send a "notifications/roots/list_changed" notification
    And the updated root list should include the new root

  Scenario: Removing a root
    Given I have registered a root with URI "file:///home/user"
    When I remove the root from the registry
    Then the root should no longer be available in the root list
    And the server should send a "notifications/roots/list_changed" notification
    And any subscriptions to the root should be removed

  Scenario: Root subscription management
    Given I have registered a root with update capability
    When a client subscribes to the root
    And the root is updated
    Then the server should track the subscription correctly
    And the client should be able to unsubscribe from the root
    And all subscriptions should be cleared when the client disconnects

  Scenario: Root validation
    When I attempt to register a root with an invalid URI
    Then the registration should fail with an appropriate error
    And the invalid root should not appear in the root list

  Scenario: Root access control
    Given I have registered roots with different access levels
    When a client requests access to a root
    Then the server should check the client's permissions
    And only grant access to roots the client is authorized to access
    And unauthorized access attempts should be rejected with appropriate errors

  Scenario: Root URI resolution
    Given I have registered a root with URI "file:///home/user"
    When a client requests a resource using a relative URI from that root
    Then the server should correctly resolve the full resource URI
    And provide access to the resource if authorized
