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
