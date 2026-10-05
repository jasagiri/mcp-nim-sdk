Feature: Pagination
  As a client of a server with long lists
  I want the lists returned page by page behind opaque cursors
  So that no answer is larger than the server chooses

  Specification: server/utilities/pagination in every version. The four list
  methods are tools/list, resources/list, resources/templates/list and
  prompts/list.

  @spec:MCP-PAGINATION-1 @feature:ftPagination
  Scenario: A list is returned page by page
    Given a server with more items than one page
    When a client sends a list request, then follows nextCursor with each next request
    Then every item arrives once and the last page has no nextCursor
    And a list that is not paged has no nextCursor

  @spec:MCP-PAGINATION-2 @feature:ftPagination
  Scenario: A cursor the server did not issue is invalid params
    Given a paged list
    When a client sends a cursor the server did not issue, or one that is not a string
    Then the answer is the error -32602

  @spec:MCP-PAGINATION-3 @feature:ftPagination
  Scenario: A server may issue cursors of its own
    Given a server whose handler pages by its own cursors
    When a client lists with such a cursor
    Then the handler's cursor is passed on unchanged and its refusal of a cursor is the answer

  @spec:MCP-PAGINATION-4 @feature:ftPagination
  Scenario: A client sends the cursor and follows the pages
    Given a server that pages a list
    When the client lists one page, lists the next with the cursor, or lists everything
    Then the cursor is sent as given, every page is followed, and a server that repeats a cursor makes the client raise instead of looping

  @spec:MCP-PAGINATION-5 @feature:ftPagination
  Scenario: A client treats a cursor as an opaque token
    Given a server whose nextCursor is the empty string
    When the client lists everything
    Then it sends the empty string as the cursor of the next request and does not take it for the end of the results
