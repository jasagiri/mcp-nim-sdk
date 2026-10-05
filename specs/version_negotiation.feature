Feature: Protocol versions
  As someone running an MCP client or server built with this SDK
  I want to know which protocol version we will speak
  So that peers of different ages still work together

  The build speaks its default version and every earlier one.

  @spec:MCP-VERSION-1
  Scenario: A released version is read from, and written as, its dated string
    Given the string "2025-06-18"
    When it is parsed
    Then the version 2025-06-18 is returned
    And a string that is not a released version gives no version
    And a version written out is its dated string

  @spec:MCP-VERSION-2
  Scenario: The build speaks the default version and every version before it
    Given a build whose default version is V
    When the supported versions are listed
    Then they are every released version up to V in ascending order
    And a version newer than V is not supported

  @spec:MCP-VERSION-3
  Scenario: A server or client cannot be created for a version newer than the default
    Given a build whose default version is V
    When a server or a client is created for a version newer than V
    Then ValueError is raised naming both versions

  @spec:MCP-VERSION-4
  Scenario: Only 2026-07-28 and later are the modern era
    Given each released version
    When asked whether it is modern
    Then only 2026-07-28 onward is

  @spec:MCP-VERSION-5
  Scenario: A server answers initialize with the requested version when it speaks it
    Given a server that speaks the versions up to V
    When a client asks for a legacy version the server speaks
    Then the answer carries that version

  @spec:MCP-VERSION-6
  Scenario: A server answers a version it does not speak with its newest legacy version
    Given a server
    When a client asks for an unknown version, or for a newer version than the server speaks
    Then the answer carries the newest legacy version the server speaks
    And asking for the modern version through initialize gets a legacy version too

  @spec:MCP-VERSION-7
  Scenario: A client does not continue on a version it does not speak
    Given a client limited to a version
    When the server answers initialize with a version the client does not speak, or with an unknown one
    Then connect fails and names that version

  @spec:MCP-VERSION-8
  Scenario: A client newer than the server settles on the server's version
    Given a client that speaks a newer version than the server
    When the client connects
    Then both use the server's version
