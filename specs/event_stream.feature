Feature: Reading a Server-Sent Events stream
  As a client that reads what a server streams
  I want the stream parsed the way WHATWG describes it
  So that events arrive whole, once, and in order whatever the chunking

  Specification: WHATWG HTML, "Server-sent events", "Parsing an event stream"
  and "Interpreting an event stream". The SDK adds one rule of its own: a
  line longer than the limit given to the parser is an error, decided before
  the line ends. The tests of the parser's other rules (field names, the one
  leading space, line ends, comments, id, retry) are those of
  tests/test_event_stream.nim; they are not given a Scenario here.

  @spec:MCP-SSE-1
  Scenario: A byte order mark counts only at the start of the stream
    Given a stream whose second line begins with a byte order mark
    When it is read
    Then that line is not read as a field and its event is not delivered

  @spec:MCP-SSE-2
  Scenario: A blank line after a dispatched event dispatches nothing
    Given an event that was dispatched
    When further blank lines follow
    Then no further event is delivered

  @spec:MCP-SSE-3
  Scenario: A line is refused only when it is longer than the limit
    Given a parser limited to ten bytes a line
    When a line of ten bytes is fed
    Then it is read, and a line of eleven bytes raises SseLimitError
