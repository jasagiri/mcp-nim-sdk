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

  @spec:MCP-SAMPLING-TOOLS-9
  Scenario: Values that are absent or of the wrong kind are reported and never crash a check
    Given params, messages, content blocks, a toolChoice or an answer that is missing, null or not an object
    When the payload is checked or its tool uses are read
    Then the problem is reported once, naming the part, and no tool use is found where there is no typed block

  @spec:MCP-SAMPLING-TOOLS-10 @feature:ftSamplingTools
  Scenario: A tool_use and a tool_result carry the fields the schema requires
    Given a tool_use block or a tool_result block in a message or an answer
    When it lacks an id, a name or an input object, a toolUseId, a content array of content blocks, or has a structuredContent that is not an object or an isError that is not a boolean
    Then exactly that field is reported, and a block with every field right is accepted

  @spec:MCP-SAMPLING-TOOLS-11 @feature:ftSamplingTools
  Scenario: Each pairing violation is reported once
    Given an assistant message of tool uses
    When the next message is not their results, or answers one id twice
    Then that is the only problem reported for the sequence

  @spec:MCP-SAMPLING-TOOLS-12 @feature:ftSamplingTools
  Scenario: The content of an answer is judged by its version and by each block
    Given the answer to a createMessage request
    When its content is an array in a version without sampling tools, holds a block of an unknown type, or completes without a tool use under a toolChoice that is not required
    Then the array and the unknown block are reported, and a completion without a tool use is valid unless the mode is required and no earlier message used a tool

  # rule
  @spec:MCP-SAMPLING-TOOLS-13 @feature:ftSampling
  Scenario: A sampling message has a role of user or assistant and a content
    Given the messages of a createMessage request
    When a message has any role other than user or assistant, no role, or no content block
    Then the server raises and sends nothing (or, from 2026-07-28, the answer is an internal error and nothing is asked)
    And a client that receives such a request answers invalid params without calling its handler
    And a user message and an assistant message with content are sent as given

  # rule
  @spec:MCP-SAMPLING-TOOLS-14 @feature:ftSampling
  Scenario: A stop reason is any string
    Given a sampling answer whose stopReason is a string the specification does not list
    When the client's handler gives it, or the server reads it, in any version that has sampling
    Then the client sends it as it is, and the server returns the answer with it, with or without tools in the request

  # rule
  # not met
  @spec:MCP-SAMPLING-TOOLS-15 @feature:ftSampling
  Scenario: includeContext other than none is sent only to a client that declared sampling.context
    Given a client that declared sampling without the context capability, in 2025-11-25 or later
    When the server asks with includeContext thisServer or allServers (sampling/createMessage, or an input request in 2026-07-28)
    Then the server raises with a capability error (or the answer is an error) and sends nothing

  @spec:MCP-SAMPLING-TOOLS-16 @feature:ftSampling
  Scenario: A server does not ask for context from a client that did not declare sampling.context
    Given a client that declared sampling without context, in 2025-11-25 or 2026-07-28
    When the server asks for a sample with includeContext thisServer or allServers
    Then the ask is refused and nothing is sent, in 2026-07-28 the request being answered with an error and not input_required
    And includeContext none, or none at all, and any includeContext to a client that declared sampling.context, are sent

  @spec:MCP-SAMPLING-TOOLS-17 @feature:ftSamplingTools
  Scenario: A tool result in a sample request conforms to the outputSchema of its tool
    Given a sampling request whose tools list a tool with an outputSchema and whose messages hold a tool_result of that tool with structuredContent
    When the structuredContent breaks the outputSchema, in 2025-11-25 or 2026-07-28
    Then the ask is refused and nothing is sent, in 2026-07-28 the request being answered with an error and not input_required
    And a structuredContent that conforms is sent
