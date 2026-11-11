Feature: Rate limiting
  How many requests a server serves for one sender, and who a sender is.

  @spec:MCP-RATE-1
  Scenario: A sender over its allowance is refused before any handler runs
    Given a server that allows two requests per second and a client that has made two
    When the client makes a third request in the same second
    Then the answer is the error 429 (outside the range JSON-RPC and MCP reserve) with data.retryAfterMs, and no handler ran for it
    And a ping counts like any other request
    And stderr says once that the sender is over its allowance, and not again until the sender has been quiet long enough to have its full allowance

  @spec:MCP-RATE-2
  Scenario: The allowance is per sender and fills again
    Given a server that allows two requests per second
    When one session has used its allowance
    Then another session is answered, and the first is answered again after it has waited
    And requests of one principal in different sessions share one allowance
    And without a principal and without a session the sender is the network address the request came from (the TCP peer, as for the limit on sessions per address), and without an address too, as on stdio, the connection

  @spec:MCP-RATE-3
  Scenario: The table of senders has a size
    Given a server that tells two senders apart, with a third speaking
    When no sender is quiet enough to have a full allowance again
    Then the sender quiet longest is forgotten and has a full allowance again
    And while a sender is quiet enough to have a full allowance again, it is the one forgotten, and a sender that has used its allowance up is not

  @spec:MCP-RATE-4
  Scenario: A limit of 0 turns the request limit off, and the default is 100 per second
    Given a server with maxRequestsPerSecond 0
    When a client makes 150 requests at once
    Then none is refused
    And a server made with the defaults allows 100 requests per second
