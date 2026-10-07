Feature: Starting a conversation
  As someone connecting an MCP client to a server
  I want both to agree on how to talk before any work is done
  So that a client of any age can use a server of any age

  Versions before 2026-07-28 start with initialize. 2026-07-28 has no
  handshake: every request names its version, and server/discover tells a
  client what a server speaks.

  @spec:MCP-LIFECYCLE-1 @feature:ftInitializeHandshake
  Scenario: initialize without a usable protocol version is invalid params
    Given a server
    When initialize arrives without protocolVersion, or with one that is not a string, or with params that are no object, or with a clientInfo that is no Implementation
    Then the answer is the invalid params error, and the handshake has not begun

  @spec:MCP-LIFECYCLE-2 @feature:ftInitializeHandshake
  Scenario: The initialize answer states only the capabilities the server has
    Given a server that declares only tools
    When it answers initialize
    Then no other capability is present
    And a client that omits capabilities, or sends null for one, is still answered, the null counting as not declared
    And the capabilities a client declares as objects are kept, and a sampling feature, experimental or extensions that is no object counts as not declared

  @spec:MCP-LIFECYCLE-3 @feature:ftInitializeHandshake
  Scenario: A client offers its version, then confirms
    Given a client limited to a legacy version
    When it connects
    Then initialize offers that version as a string and carries only the capabilities the client declared
    And the client then sends notifications/initialized
    And initialize returns the capabilities the server declared

  @spec:MCP-LIFECYCLE-4 @feature:ftPing
  Scenario: A legacy client's ping gets an empty result
    Given an initialized legacy client
    When it pings
    Then it gets an empty result

  @spec:MCP-LIFECYCLE-5 @feature:ftDiscover
  Scenario: server/discover describes the server
    Given a server that speaks 2026-07-28
    When the specification's discover request arrives
    Then the result lists the versions the server speaks newest first, its capabilities and its identity
    And instructions are included when the server has some, and omitted when it has none

  @spec:MCP-LIFECYCLE-6 @feature:ftPerRequestMetadata
  Scenario: A 2026-07-28 request is validated on its own metadata
    Given a server that speaks 2026-07-28
    When a request arrives without client capabilities
    Then the answer is invalid params
    And a request naming an unknown version is answered with an error that lists the supported versions
    And a request without any initialize is served and the server keeps no handshake state

  @spec:MCP-LIFECYCLE-7 @feature:ftPerRequestMetadata
  Scenario: A server limited to legacy versions does not know the modern era
    Given a server limited to legacy versions
    When a 2026-07-28 discover probe arrives
    Then the answer is method not found

  @spec:MCP-LIFECYCLE-8 @feature:ftDiscover
  Scenario: One server serves a legacy and a modern client in turn
    Given a server that speaks 2026-07-28
    When a legacy client and a 2026-07-28 client use it in turn
    Then each is answered in its own era
    And the legacy list result carries no 2026-07-28 field

  @spec:MCP-LIFECYCLE-9 @feature:ftDiscover
  Scenario: A client connecting to a modern server discovers it
    Given a server that speaks 2026-07-28
    When a client connects
    Then it discovers the server and sends no initialize
    And its later requests carry the protocol metadata beside their own parameters

  @spec:MCP-LIFECYCLE-10 @feature:ftDiscover
  Scenario: A client falls back to initialize when discover gets no usable answer
    Given a server limited to legacy versions, or a peer that never answers the probe
    When a client that speaks 2026-07-28 connects
    Then it sends initialize and continues with a legacy version

  @spec:MCP-LIFECYCLE-11 @feature:ftDiscover
  Scenario: A client does not connect when no version is shared
    Given a modern peer whose versions the client does not speak
    When the client connects
    Then connect fails naming the versions

  @spec:MCP-LIFECYCLE-12 @feature:ftDiscover
  Scenario: Methods that 2026-07-28 removed are method not found
    Given a 2026-07-28 request for ping, initialize, logging/setLevel or resources/subscribe
    When it is answered
    Then it is method not found, as is any unknown method

  @spec:MCP-LIFECYCLE-13 @feature:ftDiscover
  Scenario: A modern server that answered the probe too late is still met as one
    Given a modern server that answers the discover probe after its timeout
    When the client has sent initialize and the server refuses it with an unsupported-version error naming a modern version
    Then the client discovers again and connects in the modern era
    And a refusal after a probe that was answered with a legacy error is a failed connect

  @spec:MCP-RESULT-1 @feature:ftResultType
  Scenario: Results state their resultType
    Given a handler's result in 2026-07-28
    When the server completes it
    Then it gains resultType and the server identity
    And a result without resultType from an older server is read as complete
    And a resultType the client does not know makes the client raise instead of returning it

  @spec:MCP-CACHE-1 @feature:ftCacheHints
  Scenario: Cacheable results carry the server's cache policy
    Given a server with a cache policy
    When it answers tools/list
    Then the result carries ttlMs and cacheScope from the policy
    And without a policy the result is marked not reusable and private
    And values the handler already set are kept

  @spec:MCP-LIFECYCLE-14 @feature:ftDiscover
  Scenario: A client probes again once with the versions a modern server names, and otherwise follows what the versions say
    Given a server that refuses the probe with an unsupported-version error
    When it names a modern version the client speaks, the client probes again once and connects, or fails when refused a second time
    And when it names only legacy versions, or its discover result lists only legacy versions, the client sends initialize
    And when it names no versions, or names no other than it already refused, connect fails saying no version is shared
    And a probe whose sending never finishes is cancelled on the transport and not left pending once the client has timed out
    And a refusal of initialize by any other error is a failed connect even when it names a modern version

  @spec:MCP-LIFECYCLE-15 @feature:ftInitializeHandshake
  Scenario: A session that has sent initialize cannot send it again
    Given a session whose initialize has been answered
    When the same session sends initialize again
    Then the answer is the invalid request error and the first handshake stands
