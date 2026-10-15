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
  Scenario: The build speaks every version from its oldest to its default
    Given a build whose oldest version is O and whose default version is V
    When the supported versions are listed
    Then they are every released version from O to V in ascending order
    And a version older than O or newer than V is not supported
    And a server or client limited to a ceiling offers the versions from O to that ceiling

  @spec:MCP-VERSION-3
  Scenario: A server or client cannot be created for a version outside the build's range
    Given a build whose oldest version is O and whose default version is V
    When a server or a client is created for a version outside O to V
    Then ValueError is raised naming the version and both ends of the range

  @spec:MCP-VERSION-10
  Scenario: A build whose version settings are not a range of released versions does not compile
    Given the build settings for the default version and the oldest version
    When one names a version that was never released, or the oldest is newer than the default
    Then the build stops and names the setting that is wrong

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

  @spec:MCP-VERSION-9 @feature:ftPerRequestMetadata
  Scenario: A server without legacy versions tells a legacy client what it speaks
    Given a build whose oldest version is 2026-07-28
    When a client sends initialize
    Then the error is unsupported protocol version and names the versions the server speaks
    And any other request without the per-request fields is invalid params

  @spec:MCP-VERSION-11
  Scenario: A client settles the era of a server when it connects and keeps it
    Given a 2026-07-28 client that connected to a 2026-07-28 server, or to a legacy one
    When it makes further requests
    Then it sent server/discover once, initialize once for a legacy server and never for a modern one, and no probe per request

  @spec:MCP-VERSION-12
  Scenario: A registration that targets a version is refused by a side that does not speak it
    Given a server or client limited to a ceiling, and a registration that targets version T
    When the registration is made
    Then it is accepted when the side speaks T or a later version
    And otherwise ValueError is raised naming what was registered, T and the ceiling
