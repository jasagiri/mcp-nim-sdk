Feature: Elicitation
  As a server that needs something from the user
  I want to ask for it through the client
  So that a workflow can continue with what the user supplies

  Before 2026-07-28 a server asks with elicitation/create, a request of the
  server to the client. The payload rules are the same however the request
  travels.

  @spec:MCP-ELICIT-1 @feature:ftElicitation
  Scenario: A server asks for a form and gets the user's action
    Given a client that declared elicitation
    When the server sends elicitation/create with a message and a requestedSchema
    Then the client answers accept with content, decline, or cancel
    And content is present only with accept

  @spec:MCP-ELICIT-2 @feature:ftElicitation
  Scenario: The requested schema is a flat object of primitive properties
    Given a requestedSchema
    When it has a nested object, an array of objects, or a type that is not string, number, integer or boolean
    Then it is not a valid requestedSchema and the request is not sent

  @spec:MCP-ELICIT-3 @feature:ftElicitation
  Scenario: Both sides check content against the schema
    Given a form that was asked for
    When the answer lacks a required property, has a value of the wrong type, or is outside the length, bounds, enum or format
    Then the client does not send it and the server does not accept it

  @spec:MCP-ELICIT-4 @feature:ftElicitation
  Scenario: A server asks only a client that can be asked
    Given a client that did not declare elicitation, or a connection of a version before 2025-06-18
    When the server asks
    Then it fails with a capability error and sends nothing

  @spec:MCP-ELICIT-5 @feature:ftElicitation
  Scenario: A client declares elicitation and answers only for it
    Given a client with an elicitation handler
    When it connects
    Then initialize declares elicitation
    And a request that breaks the rules is answered with invalid params, and without a handler with method not found
