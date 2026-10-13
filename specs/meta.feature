Feature: The _meta field
  What a message may carry in _meta, and which of its keys are reserved.

  @spec:MCP-META-1 @feature:ftPerRequestMetadata
  Scenario: Every _meta key the SDK writes follows the key syntax of 2026-07-28 (rule)
    Given the keys the SDK defines and the _meta keys of what a 2026-07-28 server sends for discovery, a list, a call, a failed call and an unknown method
    When each is judged by the syntax of MetaObject: optional prefix of dot-separated labels and a slash, labels starting with a letter and ending with a letter or digit, a name empty or starting and ending alphanumeric
    Then every key is valid

  @spec:MCP-META-2 @feature:ftPerRequestMetadata
  Scenario: The values at the keys MCP reserves in _meta are not assumed (rule)
    Given a 2026-07-28 request or result whose _meta holds keys under a reserved prefix: io.modelcontextprotocol/, dev.mcp/, org.modelcontextprotocol.api/, com.mcp.tools/, io.mcp/
    When a key is one the SDK does not define, with any JSON value
    Then the server answers as it would without it, and a client reads the result whose reserved keys hold anything
    And when the key is one the SDK reads (logLevel, clientInfo, clientCapabilities, traceparent) with a value of the wrong type, the answer is invalid params and never an internal error
