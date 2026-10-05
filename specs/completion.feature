Feature: Argument completion
  As a user typing the argument of a prompt or a resource template
  I want the server to suggest values
  So that I can pick instead of guess

  Specification: server/utilities/completion. The completions capability was
  added in 2025-03-26 and the context of earlier arguments in 2025-06-18.

  @spec:MCP-COMPLETION-1 @feature:ftCompletion
  Scenario: A server suggests values for an argument
    Given a server with a completion handler
    When a client sends completion/complete for a prompt reference or a resource template reference
    Then the answer is a completion with values, total and hasMore from the handler
    And no more than 100 values are sent, with hasMore true when there were more

  @spec:MCP-COMPLETION-2 @feature:ftCompletionContext
  Scenario: From 2025-06-18 the arguments already resolved reach the handler
    Given a server with a completion handler
    When a client completes an argument and names the other arguments in context
    Then the handler gets them in 2025-06-18 and later, and not before

  @spec:MCP-COMPLETION-3 @feature:ftCompletionsCapability
  Scenario: A server that completes declares the completions capability
    Given a server whose handler completes
    When a client initializes or discovers it, in 2025-03-26 or later
    Then the completions capability is announced
    And a server without the capability answers completion/complete with method not found

  @spec:MCP-COMPLETION-4 @feature:ftCompletion
  Scenario: A request the server cannot complete is invalid params
    Given a server with a completion handler
    When a client sends a malformed completion/complete, or the handler rejects the argument
    Then the answer is the error -32602

  @spec:MCP-COMPLETION-5 @feature:ftCompletion
  Scenario: A client asks for completions
    Given a connected client
    When it completes an argument of a prompt or a resource template, with the context where the version has one
    Then the request carries ref, argument and context, and the client reads the values

  @spec:MCP-COMPLETION-6 @feature:ftCompletionsCapability
  Scenario: A client asks only a server that declared completions, from 2025-03-26
    Given a server that did not declare the completions capability
    When a client of 2025-03-26 or later completes an argument
    Then the client refuses without sending, whereas in 2024-11-05 the declaration is not needed
    And completing with context in 2024-11-05 is refused
