Feature: Progress and cancellation
  As someone waiting for a long request
  I want to see how far it is and to be able to stop it
  So that nothing hangs unseen

  Specification: basic/utilities/progress and basic/utilities/cancellation
  (basic/patterns/progress and basic/patterns/cancellation in 2026-07-28).

  @spec:MCP-PROGRESS-1 @feature:ftProgress
  Scenario: A request with a progress token is told how far it is
    Given a request whose _meta has a progressToken, a string or an integer
    When its handler reports progress
    Then the client gets notifications/progress with that token, as the same type, the progress, the total and the related request
    And a request without a token gets nothing

  @spec:MCP-PROGRESS-2 @feature:ftProgressMessage
  Scenario: From 2025-03-26 a progress notification may carry a message
    Given a request with a progress token
    When its handler reports progress with a message
    Then the client gets the message in 2025-03-26 and later

  @spec:MCP-PROGRESS-3 @feature:ftProgress
  Scenario: Progress increases and stops with the request
    Given a request with a progress token
    When its handler reports a progress that does not increase, or reports progress after the request was answered
    Then the first is refused and the second sends nothing

  @spec:MCP-PROGRESS-4 @feature:ftProgress
  Scenario: A progress token that is neither string nor integer is invalid params
    Given a request
    When its progressToken is of another type
    Then the answer is invalid params

  @spec:MCP-PROGRESS-5 @feature:ftProgress
  Scenario: A client asks for progress and hears it
    Given a request sent with a progress callback
    When the server reports progress
    Then the request carries a progressToken beside the caller's own _meta, and the callback sees each update in order
    And an update after the request finished, or for a token nobody holds, is ignored

  @spec:MCP-CANCEL-1 @feature:ftCancellation
  Scenario: A server stops a request the client cancelled
    Given a request in progress
    When the client sends notifications/cancelled with its id, string or integer
    Then no response is sent and the handler sees the cancellation, so a wait on it ends
    And the handler can read the reason, which is empty when the notification has none or it is not a string

  @spec:MCP-CANCEL-2 @feature:ftCancellation
  Scenario: A cancellation that refers to nothing live is ignored
    Given a server
    When a cancellation names an id nobody sent, a request already answered, or the initialize request
    Then the server goes on, an answer already given stands, and initialize is answered anyway

  @spec:MCP-CANCEL-3 @feature:ftCancellation
  Scenario: Cancellation is scoped to the session
    Given two sessions with the same request id in flight
    When one client cancels it
    Then the other's request goes on
    And a session that ends cancels its requests in flight

  @spec:MCP-CANCEL-4 @feature:ftCancellation
  Scenario: A client gives up on a request and tells the server
    Given a request the server does not answer
    When the client's timeout passes, or the caller cancels the request
    Then the request raises a timeout or a cancelled error, the server is told to cancel that id with the reason, and a late response is ignored
    And a cancel before the call, or after the request finished, sends nothing
    And a connect that times out sends no cancellation, because initialize cannot be cancelled

  @spec:MCP-CANCEL-5 @feature:ftCancellation
  Scenario: An HTTP client that closes the stream cancels the request
    Given a Streamable HTTP request in progress on 2026-07-28
    When the client closes the connection
    Then the server is told the request was cancelled, and an answer it gives anyway is dropped without an error

  @spec:MCP-CANCEL-6 @feature:ftCancellation
  Scenario: Before 2026-07-28 a disconnect is not a cancellation
    Given a Streamable HTTP request whose connection was cut, in a version before 2026-07-28
    When the server finishes the request
    Then it was not treated as cancelled
