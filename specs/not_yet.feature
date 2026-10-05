Feature: Not implemented yet
  What the specification of some version defines and this SDK does not do.
  Every Scenario here is @unimplemented: a statement of what is owed, with no
  test. When one is implemented, the tag goes and a test is listed in tests.map.

  @spec:MCP-CANCEL-1 @feature:ftCancellation @unimplemented
  Scenario: A cancelled request stops
    Given a request in progress
    When the peer sends a cancellation for it
    Then the work stops and no result is sent
