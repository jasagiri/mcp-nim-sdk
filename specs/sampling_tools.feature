Feature: Sampling with tools
  As a server that wants the client's model to act with tools
  I want to offer tools in a sampling request and carry the conversation through tool uses
  So that an agent loop can run inside one sampling flow

  2025-11-25 adds `tools` and `toolChoice` to sampling/createMessage, the
  tool_use and tool_result content blocks and the stop reason toolUse. Before
  2026-07-28 the request is a request of the server; the payload rules are
  the same however the request travels.

  @spec:MCP-SAMPLING-TOOLS-1 @feature:ftSamplingTools
  Scenario: A server offers tools and the model answers with tool uses
    Given a client that declared sampling.tools and a connection of 2025-11-25 or later
    When the server sends sampling/createMessage with tools and toolChoice
    Then the client's answer may stop with toolUse and a content array of tool_use blocks
    And the server reads the tool uses from it

  @spec:MCP-SAMPLING-TOOLS-2 @feature:ftSamplingTools
  Scenario: Tools are sent only to a client that declared them
    Given a client without sampling.tools, or a connection of 2025-06-18
    When the server sends a request with tools or toolChoice
    Then it fails with a capability error and sends nothing
    And a client that receives such a request answers invalid params

  @spec:MCP-SAMPLING-TOOLS-3 @feature:ftSamplingTools
  Scenario: A client declares sampling.tools only when its handler supports tools
    Given a client with a sampling handler
    When it connects
    Then initialize declares sampling.tools exactly when the handler was set up for tools

  @spec:MCP-SAMPLING-TOOLS-4 @feature:ftSamplingTools
  Scenario: Tool uses and tool results pair up in the messages
    Given the messages of a request
    When an assistant message holds tool_use blocks
    Then a user message of exactly their tool_result blocks follows, each id answered once, and nothing else is in that message

  @spec:MCP-SAMPLING-TOOLS-5 @feature:ftSamplingTools
  Scenario: Messages that break the pairing are refused on both sides
    Given a request whose tool results are mixed with other content, missing, or unmatched
    When the server would send it, or the client receives it
    Then the server raises and sends nothing, and the client answers invalid params

  @spec:MCP-SAMPLING-TOOLS-6 @feature:ftSamplingTools
  Scenario: An answer is consistent with the tools of its request
    Given a request with tools
    When the answer stops for toolUse without a tool_use block, or holds tool_use blocks under toolChoice none, or completes under required before any tool was used
    Then it is not a valid result and the server does not accept it

  @spec:MCP-SAMPLING-TOOLS-7 @feature:ftSamplingTools
  Scenario: A client does not send an answer that breaks the rules
    Given a handler that answers a request with tools inconsistently
    When the server asks
    Then the server gets an internal error and not the answer

  @spec:MCP-SAMPLING-TOOLS-8
  Scenario: A sampling message holds only the content types of its version
    Given a connection of a version before 2025-03-26
    When a sampling/createMessage request has a message with an audio block
    Then the request is invalid, because SamplingMessage.content is text or image there, and from 2025-03-26 on it is accepted

  @spec:MCP-SAMPLING-g2f-sampling-1
  Scenario: Values that are absent or of the wrong kind are reported and never crash a check
    Given params, messages, content blocks, a toolChoice or an answer that is missing, null or not an object
    When the payload is checked or its tool uses are read
    Then the problem is reported once, naming the part, and no tool use is found where there is no typed block

  @spec:MCP-SAMPLING-g2f-sampling-2 @feature:ftSamplingTools
  Scenario: A tool_use and a tool_result carry the fields the schema requires
    Given a tool_use block or a tool_result block in a message or an answer
    When it lacks an id, a name or an input object, a toolUseId, a content array of content blocks, or has a structuredContent that is not an object or an isError that is not a boolean
    Then exactly that field is reported, and a block with every field right is accepted

  @spec:MCP-SAMPLING-g2f-sampling-3 @feature:ftSamplingTools
  Scenario: Each pairing violation is reported once
    Given an assistant message of tool uses
    When the next message is not their results, or answers one id twice
    Then that is the only problem reported for the sequence

  @spec:MCP-SAMPLING-g2f-sampling-4 @feature:ftSamplingTools
  Scenario: The content of an answer is judged by its version and by each block
    Given the answer to a createMessage request
    When its content is an array in a version without sampling tools, holds a block of an unknown type, or completes without a tool use under a toolChoice that is not required
    Then the array and the unknown block are reported, and a completion without a tool use is valid unless the mode is required and no earlier message used a tool
