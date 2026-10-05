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

  @spec:MCP-TOOLANN-1 @feature:ftToolAnnotations
  Scenario: A tool's annotations are listed
    Given a server whose tool has annotations and a client of a version that has them
    When the client lists tools
    Then the tool carries title and every hint the server set

  @spec:MCP-TOOLANN-2 @feature:ftToolAnnotations
  Scenario: A version without annotations gets none
    Given a server whose tool has annotations and a client of a version before 2025-03-26
    When the client lists tools
    Then the tool has no annotations field

  @spec:MCP-TOOLANN-3 @feature:ftToolAnnotations
  Scenario: A client reads the hints with the specification's defaults
    Given a tool listed with some annotations
    When the client reads them
    Then an unset hint has its default, destructiveHint and idempotentHint count only for a tool that is not read-only, and the display name is title, annotations.title, name
