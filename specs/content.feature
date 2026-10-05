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

  @spec:MCP-STRUCTOUT-1 @feature:ftStructuredToolOutput
  Scenario: outputSchema and structuredContent are sent to a version that has them
    Given a tool with an outputSchema and a result that conforms to it
    When a client of a version with structured output lists and calls the tool
    Then the definition carries the outputSchema and the result carries structuredContent

  @spec:MCP-STRUCTOUT-2 @feature:ftStructuredToolOutput
  Scenario: A version without structured output gets neither field
    Given a tool with an outputSchema and a result with structuredContent
    When a client of a version before 2025-06-18 lists and calls the tool
    Then neither field is sent and, when the result has no content of its own, the serialized JSON is its text

  @spec:MCP-STRUCTOUT-3 @feature:ftStructuredToolOutput
  Scenario: The server checks structuredContent against the outputSchema
    Given a tool with an outputSchema
    When its result has no structuredContent, or one that does not conform, or the schema cannot be checked
    Then the client gets an internal error that names the tool, except for a result that reports a failure with isError

  @spec:MCP-STRUCTOUT-4 @feature:ftStructuredToolOutput
  Scenario: structuredContent is an object before 2026-07-28 and any JSON value after
    Given a tool whose outputSchema describes an array
    When it returns an array as structuredContent
    Then a 2026-07-28 client receives it and an earlier one gets an internal error

  @spec:MCP-STRUCTOUT-5 @feature:ftStructuredToolOutput
  Scenario: The client checks the result of a listed tool
    Given a tool that was listed with an outputSchema
    When the client calls it and the result has no structuredContent or one that does not conform
    Then the call raises a protocol error, unless validation is turned off for the call or the result reports a failure

  @spec:MCP-STRUCTOUT-6 @feature:ftStructuredToolOutput
  Scenario: A result is returned unchecked when nothing says what to check
    Given a tool without an outputSchema, a tool that was never listed, or a client of a version without structured output
    When the tool's result carries structuredContent
    Then it is passed through unchecked

  @spec:MCP-RESLINK-1 @feature:ftResourceLinks
  Scenario: A resource link is sent to a version that has it
    Given a tool result and a prompt message that hold a resource_link block
    When a client of a version with resource links receives them
    Then the block arrives as the handler wrote it

  @spec:MCP-RESLINK-2 @feature:ftResourceLinks
  Scenario: A version without resource links is given the name and uri as text
    Given a tool result and a prompt message that hold a resource_link block
    When a client of a version before 2025-06-18 receives them
    Then a text block with the link's name and uri stands in its place

  @spec:MCP-RESLINK-3 @feature:ftResourceLinks
  Scenario: A client reads a resource link and follows it
    Given a tool result with a resource_link block
    When the client reads the result and then reads the resource the link names
    Then the item carries uri, name, title, description, MIME type and size, a link without uri or name is a protocol error, and resources/read asks for the link's uri
