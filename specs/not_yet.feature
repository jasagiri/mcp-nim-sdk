Feature: Not implemented yet
  What the specification of some version defines and this SDK does not do.
  Every Scenario here is @unimplemented: a statement of what is owed, with no
  test. When one is implemented, the tag goes and a test is listed in tests.map.

  @spec:MCP-RESOURCES-1 @feature:ftResources @unimplemented
  Scenario: A client lists and reads resources
    Given a server with resources and a connected client
    When the client sends resources/list and resources/read
    Then it receives the resources and their contents

  @spec:MCP-PROMPTS-1 @feature:ftPrompts @unimplemented
  Scenario: A client lists prompts and gets one
    Given a server with prompts and a connected client
    When the client sends prompts/list and prompts/get
    Then it receives the prompts and the prompt's messages

  @spec:MCP-PAGINATION-1 @feature:ftPagination @unimplemented
  Scenario: A list is returned page by page
    Given a server with more items than one page
    When the client sends a list request with a cursor
    Then it receives the next page and a cursor for the one after

  @spec:MCP-CANCEL-1 @feature:ftCancellation @unimplemented
  Scenario: A cancelled request stops
    Given a request in progress
    When the peer sends a cancellation for it
    Then the work stops and no result is sent
