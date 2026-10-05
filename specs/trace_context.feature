Feature: Trace context (2026-07-28)
  As an operator who traces requests across MCP peers
  I want traceparent, tracestate and baggage to travel in _meta
  So that a server's work shows up in the trace of the client's request

  @spec:MCP-TRACE-1 @feature:ftTraceContext
  Scenario: The values follow the W3C formats
    Given a traceparent, tracestate or baggage value
    When it is validated
    Then a well-formed value is accepted and a malformed one is rejected

  @spec:MCP-TRACE-2 @feature:ftTraceContext
  Scenario: A client sends trace context with a request
    Given a connected 2026-07-28 client
    When it sends a request with a trace context in its options
    Then the request's _meta carries the keys, and a malformed value raises before anything is sent

  @spec:MCP-TRACE-3 @feature:ftTraceContext
  Scenario: A handler reads the trace context and the server passes it on
    Given a request whose _meta carries trace context
    When the handler runs and reports progress and logs
    Then the handler sees the context and those notifications carry it

  @spec:MCP-TRACE-4 @feature:ftTraceContext
  Scenario: A malformed trace context is invalid params
    Given a request whose _meta has a malformed traceparent
    When the server receives it
    Then it answers invalid params and runs no handler

  @spec:MCP-TRACE-5 @feature:ftTraceContext
  Scenario: Earlier versions carry no trace context
    Given a connection in a version before 2026-07-28
    When a request has trace context keys or the client has a trace context to send
    Then the server ignores the keys and the client leaves them out
