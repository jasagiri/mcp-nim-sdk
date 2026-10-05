Feature: Not implemented yet
  What the specification of some version defines and this SDK does not do.
  Every Scenario here is @unimplemented: a statement of what is owed, with no
  test. When one is implemented, the tag goes and a test is listed in tests.map.

  @spec:MCP-MRTR-1 @feature:ftMultiRoundTripRequests @unimplemented
  Scenario: A client fulfils the input a server asked for and retries
    Given a 2026-07-28 server that answers a request with an InputRequiredResult holding inputRequests
    When the client receives it
    Then it builds a response for each input request, retries the original request under a new id with the inputResponses, and echoes requestState exactly as received, or sends none when there was none

  @spec:MCP-SUBSCRIPTIONS-1 @feature:ftSubscriptionsListen @unimplemented
  Scenario: A client listens for the notifications it chose
    Given a 2026-07-28 server
    When a client sends subscriptions/listen naming the event types it wants
    Then the server's first message is notifications/subscriptions/acknowledged with the filter it accepted
    And later notifications carry the subscriptionId of the request, and none goes out on a stream that did not ask
