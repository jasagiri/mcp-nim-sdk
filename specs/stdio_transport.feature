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
