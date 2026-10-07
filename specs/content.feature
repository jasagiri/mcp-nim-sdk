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

  @spec:MCP-AUDIO-4 @feature:ftAudioContent
  Scenario: A sampling answer with audio is fitted to the version
    Given a client whose sampling handler answers with audio content
    When the server of a version without audio content asks
    Then the answer's content is text that names the audio it stands for
    And a version with audio content gets the audio block

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
    And a later listing of the tool without an outputSchema ends the checking

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

  @spec:MCP-TITLE-1 @feature:ftTitleFields
  Scenario: Titles are sent to a version that has them
    Given tools, resources, resource templates, prompts and prompt arguments that have titles
    When a client of a version with title fields lists them
    Then every title is sent

  @spec:MCP-TITLE-2 @feature:ftTitleFields
  Scenario: A version without title fields gets none
    Given the same items
    When a client of a version before 2025-06-18 lists them
    Then no title is sent, the names are, and a tool's annotations.title stays where the version has annotations

  @spec:MCP-TITLE-3 @feature:ftTitleFields
  Scenario: A client shows the title and falls back to the name
    Given listed items with and without titles
    When the client asks for their display names
    Then it is the title when there is one and the name otherwise

  @spec:MCP-ICONS-1 @feature:ftIcons
  Scenario: Icons are sent to a version that has them
    Given tools, resources, resource templates, prompts and resource links that have icons
    When a client of a version with icons lists or calls them
    Then the icons arrive as the handler wrote them

  @spec:MCP-ICONS-2 @feature:ftIcons
  Scenario: A version without icons gets none
    Given the same items
    When a client of a version before 2025-11-25 lists or calls them
    Then no icons field is sent

  @spec:MCP-ICONS-3 @feature:ftIcons
  Scenario: A client reads icons
    Given listed items with icons
    When the client lists them
    Then each item carries src, mimeType, sizes and theme, and a malformed icon is a protocol error

  @spec:MCP-ICONS-4 @feature:ftIcons
  Scenario: A client screens icon URIs before using them
    Given icons with various URIs
    When the client screens them, with or without the server's origin
    Then only https URLs (of the server's origin when it is given) and base64 image data URIs remain

  @spec:MCP-IMPL-1 @feature:ftImplementationDescription
  Scenario: A server describes itself with the fields of the version
    Given a server with a title, description, website URL and icons
    When a legacy client of each version initializes
    Then serverInfo has the fields of that version, and from 2025-11-25 description and websiteUrl

  @spec:MCP-IMPL-2 @feature:ftImplementationDescription
  Scenario: A client describes itself with the fields of the version
    Given a client with a title, description, website URL and icons
    When it initializes in each legacy version
    Then clientInfo has the fields of that version

  @spec:MCP-IMPL-3 @feature:ftImplementationDescription
  Scenario: The peer's description is read
    Given a peer whose Implementation has a description and a website URL
    When the server reads clientInfo or the client reads serverInfo, in the handshake or in 2026-07-28 discovery and request metadata
    Then the fields are kept, and a field of the wrong type is invalid params for the server and a protocol error for the client

  @spec:MCP-TITLE-4 @feature:ftTitleFields
  Scenario: An Implementation has a title only in versions with title fields
    Given a server and a client with titles
    When they introduce themselves in each version
    Then the title is sent from 2025-06-18 on

  @spec:MCP-ICONS-5 @feature:ftIcons
  Scenario: An Implementation has icons only in versions with icons
    Given a server and a client with icons
    When they introduce themselves in each version
    Then the icons are sent from 2025-11-25 on

  @spec:MCP-CONTENT-FIELDS-1
  Scenario: An optional string field of another type is a protocol violation
    Given a server whose answer has a title, description, mimeType, text, blob or nextCursor that is not a string
    When the client reads the answer
    Then it raises a protocol error naming the operation and the field, and an absent field is still none

  @spec:MCP-CONTENT-FIELDS-2
  Scenario: A content block of the wrong shape is a protocol violation
    Given a server whose answer holds a content block that is not an object, or an embedded resource without its resource object
    When the client reads the answer
    Then it raises a protocol error
    And an embedded resource without a mimeType is written back without one

  @spec:MCP-ICONS-6 @feature:ftIcons
  Scenario: An icon is fetched the way the security considerations ask
    Given an icon of a server whose origin is known
    When the client fetches it
    Then it sends no credentials, stays on the origin of the server through redirects, limits the size, and accepts only allowed image types found in the bytes whatever the declared MIME type says

  @spec:MCP-ICONS-g2f-ap-a-1 @feature:ftIcons
  Scenario: The type of an icon is the one its first bytes say
    Given the first bytes of a fetched icon
    When they are a PNG, JPEG or WebP signature, even with nothing after it, or markup that holds an svg element at its start
    Then the icon is of that type
    And a signature cut short, or XML or HTML that holds no svg element at its start, is of no known type

  @spec:MCP-ICONS-g2f-ap-a-2 @feature:ftIcons
  Scenario: A data URI icon is within the size limit when its decoded bytes are
    Given a data URI icon and a limit of N bytes
    When the decoded bytes are N bytes
    Then the icon is read
    And when they are N + 1 bytes it is refused
