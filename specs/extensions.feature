Feature: Extensions (2026-07-28)
  As the author of an MCP extension
  I want to declare it, negotiate it and plug its methods and result types into the SDK
  So that an extension needs no change to the core

  @spec:MCP-EXT-1 @feature:ftExtensions
  Scenario: Identifiers and the capability wire form follow the specification
    Given extension identifiers and the specification's capability examples
    When they are validated, parsed and written
    Then malformed identifiers are rejected and the examples round-trip

  @spec:MCP-EXT-2 @feature:ftExtensions
  Scenario: The server declares the extensions it registered
    Given a server with a registered extension
    When a 2026-07-28 client discovers it or a legacy client initializes
    Then the discover capabilities list the extension and the legacy ones do not

  @spec:MCP-EXT-3 @feature:ftExtensions
  Scenario: An extension method is served for clients that declared the extension
    Given a registered extension method
    When a client that declared the extension calls it
    Then the handler runs with the client's settings and its result is returned

  @spec:MCP-EXT-4 @feature:ftExtensions
  Scenario: A client without the extension gets the missing-capability error
    Given a registered extension method or a handler that requires the extension
    When a client that did not declare the extension makes the request
    Then the answer is -32021 naming the extension in requiredCapabilities

  @spec:MCP-EXT-5 @feature:ftExtensions
  Scenario: An extension defines a result type
    Given an extension that declared a resultType
    When its handler returns it
    Then the result passes through, and a type no extension defines is an internal error
    And a type of an extension the client did not declare gets the missing-capability error, and a resultType that is not a string is an internal error

  @spec:MCP-EXT-6 @feature:ftExtensions
  Scenario: Registrations are checked
    Given an identifier without a prefix, a core method or a core result type
    When it is registered
    Then registration raises ValueError

  @spec:MCP-EXT-7 @feature:ftExtensions
  Scenario: A client declares its extensions and reads the server's
    Given a client that declared an extension before connecting
    When it sends requests and connects to a server that declared extensions
    Then its capabilities carry the declaration in 2026-07-28 only and it can read the server's settings

  @spec:MCP-EXT-8 @feature:ftExtensions
  Scenario: A client does not call what the server cannot serve
    Given a server without the extension
    When the client calls an extension method
    Then it raises McpUnsupportedError and sends nothing

  @spec:MCP-EXT-9 @feature:ftExtensions
  Scenario: A client accepts the result types of its extensions
    Given both sides support an extension that defines a resultType
    When the server answers with it
    Then the client returns the result, and raises for a type it does not know

  @spec:MCP-EXT-10 @feature:ftExtensions
  Scenario: A legacy handshake carries only the extensions registered for it
    Given a client and a server that registered extensions without onLegacyHandshake
    When a client of a version before 2026-07-28 initializes
    Then the request and the result are those of a peer with no extensions

  @spec:MCP-EXT-11 @feature:ftExtensions
  Scenario: A client declares an extension in a legacy initialize when told to
    Given a client that declared an extension with onLegacyHandshake and another without
    When it sends initialize in a version before 2026-07-28
    Then the capabilities carry the first and not the second

  @spec:MCP-EXT-12 @feature:ftExtensions
  Scenario: A server reads the extensions of a legacy initialize
    Given a legacy client that declared an extension in initialize
    When a handler asks what the client declared
    Then it sees the settings, and sees nothing for a client that did not declare it

  @spec:MCP-EXT-13 @feature:ftExtensions
  Scenario: A server announces an extension in a legacy initialize result when told to
    Given a server with an extension registered with onLegacyHandshake and another without
    When a client of a version before 2026-07-28 initializes
    Then the result announces the first and not the second

  @spec:MCP-EXT-14 @feature:ftExtensions
  Scenario: An extension the server alone declares is served to any client
    Given a method registered for an extension that asks no declaration of the client
    When a client that declared nothing calls it
    Then the server serves it, and the client sends it without having declared the extension
    And the client still sends nothing to a server that did not declare the extension

  @spec:MCP-EXT-15 @feature:ftExtensions
  Scenario: A top-level capability the core does not define is kept for the extensions that read it
    Given a server that declares a capability the core does not define next to core ones
    When the client connects, in any version
    Then serverCapability returns the settings of the one the core does not define, and nothing for core capabilities or non-object values
    And a server whose capabilities are not an object is taken to have declared nothing
