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

  @spec:MCP-ELICIT-ENUM-1 @feature:ftEnumSchemas
  Scenario: A form offers titled and untitled, single and multi-select enums
    Given a protocol version of 2025-11-25 or later
    When a property is a string with enum or oneOf, or an array whose items are a string enum or anyOf titled options
    Then it is a valid property, with minItems and maxItems checked on a multi-select
    And before 2025-11-25 only the plain enum is valid

  @spec:MCP-ELICIT-ENUM-2 @feature:ftEnumSchemas
  Scenario: A selection is checked against the offered values
    Given a form with an enum property
    When the answer holds a value that is not one of the options, or a multi-select with too few or too many entries
    Then the answer does not match the schema

  @spec:MCP-ELICIT-ENUM-3 @feature:ftEnumSchemas
  Scenario: A version without the enum shapes refuses them on the wire
    Given a connection of 2025-06-18
    When the server asks for a titled or multi-select enum, or the client receives such a request
    Then the server sends nothing and the client answers invalid params

  @spec:MCP-ELICIT-DEFAULT-1 @feature:ftElicitationDefaults
  Scenario: Primitive properties carry a default value
    Given a protocol version of 2025-11-25 or later
    When a string, number, integer, enum or boolean property has a default
    Then the default is accepted if it fits the property
    And before 2025-11-25 only a boolean has one

  @spec:MCP-ELICIT-DEFAULT-2 @feature:ftElicitationDefaults
  Scenario: A default that does not fit its property is refused
    Given a property with a default
    When the default has the wrong type, is outside the bounds or length, or is not one of the enum values
    Then the schema is not a valid requestedSchema
