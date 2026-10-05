Feature: Content of tools, resources and prompts
  What a server sends and a client reads in tool definitions, tool results and
  the descriptive fields of the lists, as each protocol version defines them.

  @spec:MCP-SCHEMA-1 @feature:ftJsonSchema2020
  Scenario: A schema without $schema is JSON Schema 2020-12
    Given a tool schema that has no $schema
    When an instance is validated against it
    Then the 2020-12 keywords apply

  @spec:MCP-SCHEMA-2 @feature:ftJsonSchema2020
  Scenario: A schema in a dialect that cannot be checked is reported
    Given a tool schema whose $schema names a dialect this SDK does not validate
    When an instance is validated against it
    Then the dialect is reported as unsupported and the instance is not taken as valid
