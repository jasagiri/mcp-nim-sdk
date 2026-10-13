Feature: stdio transport
  As someone running an MCP server as a program
  I want a client to talk to it over standard input and output
  So that a client can start a server without a network

  @spec:MCP-STDIO-1 @feature:ftStdio
  Scenario: One message is one line
    Given a transport on a pair of streams
    When two messages arrive on two lines, with blank lines or CRLF endings between
    Then each line is one message
    And a message sent is written as one line

  @spec:MCP-STDIO-2 @feature:ftStdio
  Scenario: The end of input and bad lines
    Given a server on a stdio transport
    When the input ends, the transport reports that the peer closed it
    And a line that is not JSON is answered with a parse error with a null id, and reading goes on

  @spec:MCP-STDIO-3 @feature:ftStdio
  Scenario: A client starts a server as a child process
    Given a server program
    When a client connects through a process transport
    Then it calls a tool in the build's default version
    And against a child limited to 2024-11-05 both settle on 2024-11-05
    And closing the client ends the child

  @spec:MCP-STDIO-4 @feature:ftStdio
  Scenario: A child that cannot be used is reported
    Given a command that does not exist, or a child that never answers
    When a process transport is made, or the client connects
    Then McpTransportError names the command, or the wait can time out while the dispatcher keeps running

  @spec:MCP-STDIO-5 @feature:ftStdio
  Scenario: A server reads and writes its own descriptors
    Given a server that reads its stdin with the transport
    When a write holds blank lines, CRLF lines, several lines or a last line without a newline
    Then each line is one message in order, and the end of input is reported
    And a message of exactly the size limit is accepted, and more than the limit without a newline fails naming the limit
    And a line that is not JSON is answered with a parse error with a null id, and reading goes on
    And closing the transport releases the stdin descriptor, and a stream transport flushes what it sends and closes both streams

  @spec:MCP-STDIO-6 @feature:ftStdio
  Scenario: A client looks after the child it started
    Given a server program started through a process transport
    When the child prints a line that is not JSON, or fills its stderr, or ignores the closing of its stdin, or also ignores SIGTERM
    Then the noise is reported on stderr and not answered to the child, and the child's stderr is passed on
    And the child is asked to exit by closing its stdin, then terminated, then killed, and the pipe descriptors are released

  @spec:MCP-STDIO-7 @feature:ftStdio
  Scenario: A stdio server writes only JSON-RPC messages to its stdout (a rule)
    Given a server on a stdio transport
    When any line arrives on its stdin: a request, a notification, a request its handler fails, an unknown method, a line that is not JSON, a blank line, JSON that is not an object, bytes that are not UTF-8
    Then every line the server writes to its stdout is a JSON-RPC request, notification or response
    And a line that is not JSON is answered with a parse error with a null id

  @spec:MCP-STDIO-8 @feature:ftStdio
  Scenario: A stdio client writes only JSON-RPC requests and notifications to its server's stdin (a rule)
    Given a client that started a server as a child process
    When it connects, lists tools, calls a tool with non-ASCII text, gives up on a slow call and closes
    Then every line the server received on its stdin is a JSON-RPC request or notification

  @spec:MCP-STDIO-9 @feature:ftStdio
  Scenario: A stdio transport writes UTF-8 and reads it (a rule)
    Given a transport on a pair of streams
    When a message is sent whose strings are of any script (empty, ASCII, Japanese, accented, four-byte, line separator, control characters)
    Then the bytes written are valid UTF-8 and read back as the same strings
    And a line of UTF-8 bytes is read as the characters it encodes
    And a string holding bytes that are not UTF-8 is never written as such: the send is refused or the bytes are replaced

  @spec:MCP-STDIO-10 @feature:ftStdio
  Scenario: A server that ends its own session is seen as a closed connection
    Given a client connected to a child server
    When the server exits while a call waits
    Then the call fails as a closed connection and closing the client succeeds and the child is gone

  @spec:MCP-STDIO-11 @feature:ftParameterHeaders
  Scenario: A stdio client does not apply x-mcp-header (2026-07-28)
    Given a 2026-07-28 server over stdio that lists a tool whose x-mcp-header declaration is invalid
    When the client lists tools and calls that tool
    Then the tool is listed and the call is sent

  @spec:MCP-STDIO-12 @feature:ftStdio
  Scenario: A stdio server that ends of its own accord ends the client's connection
    Given a server started as a child process that exits while a request of the client waits
    When its output stream ends
    Then the waiting request fails as a closed connection
    And the client is shut down, a later request fails the same way and close completes
