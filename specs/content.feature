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

  @spec:MCP-AUDIO-1 @feature:ftAudioContent
  Scenario: Audio content is sent to a version that has it
    Given a tool result and a prompt message that hold an audio block
    When a client of a version with audio content receives them
    Then the audio block arrives as the handler wrote it

  @spec:MCP-AUDIO-2 @feature:ftAudioContent
  Scenario: A version without audio content is told in text
    Given a tool result and a prompt message that hold an audio block
    When a client of a version before 2025-03-26 receives them
    Then a text block that names the audio type stands in the audio block's place

  @spec:MCP-AUDIO-3 @feature:ftAudioContent
  Scenario: A client reads an audio block
    Given a server that answers with an audio block in a tool result or a prompt message
    When the client reads the answer
    Then the item is audio with its data and MIME type, and a block without them is a protocol error
