Feature: Hooks for extensions in the server's request handling
  As the author of an extension
  I want to see a request's _meta, filter an answer, choose a list handler and send list-changed with params
  So that an extension can act inside a request without changing what a server without it does

  Specification: SDK behaviour, not a protocol rule.

  @spec:MCP-HOOKS-1
  Scenario: Registering no hook changes nothing
    Given a server whose handlers never read ctx.meta and that registered no response filter and no list scope (or one that answers nil)
    When it serves requests, whatever their _meta, and when notifyListChanged is never called
    Then each result is what the handler returned, the registered list handlers serve and validate tool input, and no list-changed notification is sent
    And notifyToolListChanged sends it as before, with empty params

  @spec:MCP-HOOKS-2
  Scenario: Hooks act in the order they were added
    Given request interceptors, tool list transforms and listen filter hooks registered one after another
    When a request arrives, tools/list is asked, or subscriptions/listen is asked
    Then the first interceptor that answers ends the matter, each tool passes through the transforms in turn, and each listen hook sees what the earlier ones agreed to
    And a listen hook that raises a request error refuses the request and subscribes nothing

  @spec:MCP-HOOKS-2 @feature:ftResultType
  Scenario: A filter cannot make a 2026-07-28 result something that is not an object
    Given a response filter that replaces the result of a request with a value that is not a JSON object
    When a 2026-07-28 client makes that request
    Then the answer is an internal error
