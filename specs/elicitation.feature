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

  @spec:MCP-ELICIT-URL-1 @feature:ftUrlElicitation
  Scenario: A server sends the user to a URL
    Given a client that declared the url mode and a connection of 2025-11-25 or later
    When the server sends elicitation/create with mode url, a message, an elicitationId and a url
    Then the client answers accept, decline or cancel, and an accept has no content

  @spec:MCP-ELICIT-URL-2 @feature:ftUrlElicitation
  Scenario: A server asks only in a mode the client declared
    Given a client whose elicitation capability is empty, or form only, or a connection of 2025-06-18
    When the server asks in url mode
    Then it fails with a capability error and sends nothing
    And an empty elicitation capability means the form mode alone

  @spec:MCP-ELICIT-URL-3 @feature:ftUrlElicitation
  Scenario: A client declares the modes it supports and refuses the others
    Given a client with an elicitation handler for chosen modes
    When it connects
    Then initialize declares exactly those modes
    And a request in another mode is answered with invalid params

  @spec:MCP-ELICIT-URL-4 @feature:ftUrlElicitation
  Scenario: The end of an out-of-band interaction is announced to one client
    Given an accepted URL request
    When the server sends notifications/elicitation/complete to that client with the elicitationId
    Then the client's callback runs once, and a notification for an unknown or completed id is ignored

  @spec:MCP-ELICIT-URL-5 @feature:ftUrlElicitation
  Scenario: A request that needs a URL elicitation fails with code -32042
    Given a handler that cannot go on until the user has done a URL elicitation
    When it raises the URL elicitation required error
    Then the call fails with code -32042 and data.elicitations lists the URL requests
    And the client reads them back, and malformed data is a protocol error

  @spec:MCP-ELICIT-g2e-elicit-b-1 @feature:ftElicitation
  Scenario: A requested schema's bounds, counts, enums and properties are well formed
    Given a requestedSchema
    When a bound is not a number or is inverted, an enum is empty or holds a non-string, a count is not a non-negative integer, a multi-select has no items, or a property is not an object, has no type, or required is not an array
    Then the property or field is named in the report, and equal bounds are accepted

  @spec:MCP-ELICIT-g2e-elicit-b-2 @feature:ftElicitation
  Scenario: Params, results and content that are not objects, and an unknown mode, are reported as such
    Given elicitation/create params, an answer or its content
    When the params, the answer or the content is not an object, or the mode is neither form nor url
    Then the report says so, and the same mode check applies to the answer of a request

  @spec:MCP-ELICIT-g2e-elicit-b-3 @feature:ftElicitation
  Scenario: A value at the limit of its bounds is accepted and a date-time offset is RFC 3339
    Given a form with length and numeric bounds and a date-time property
    When the content sits exactly on a bound, or carries a numeric offset
    Then it is accepted, and an offset that is not (+|-)HH:MM with HH up to 23 and MM up to 59 is reported

  @spec:MCP-ELICIT-g2e-elicit-b-4 @feature:ftElicitation
  Scenario: A payload error joins its problems and refuses to be built without one
    Given a list of problems
    When a payload error is built
    Then its message is the context and the problems joined by semicolons, and an empty list is a contract violation

  @spec:MCP-ELICIT-g2e-elicit-b-5 @feature:ftUrlElicitation
  Scenario: A handler asks in url mode on behalf of its request, and a task is working again once the answer is in
    Given a tool handler that asks the client in url or form mode, in a task or not
    When the client answers
    Then the answer is the one the handler reads, the request belongs to the tool call, and the task needs input only while the answer is outstanding

