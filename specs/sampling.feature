Feature: MCP Sampling
  As an MCP server developer
  I want to request LLM completions through clients
  So that I can utilize LLM capabilities while maintaining security and privacy

  Scenario: Basic sampling request
    Given an MCP server with sampling capability
    When the server sends a sampling/createMessage request
    And the request contains a valid message array
    And the request specifies maxTokens
    Then the client should process the sampling request
    And the client should respond with a completion
    And the completion should include model information
    And the completion should include the generated text

  Scenario: Sampling with system prompt
    Given an MCP server with sampling capability
    When the server sends a sampling/createMessage request
    And the request includes a system prompt
    Then the client should consider the system prompt
    And the client should respond with a completion
    And the completion should reflect the system prompt guidance

  Scenario: Sampling with context inclusion
    Given an MCP server with sampling capability
    When the server sends a sampling/createMessage request
    And the request specifies includeContext as "thisServer"
    Then the client should include relevant context from the requesting server
    And the client should respond with a completion
    And the completion should reflect awareness of the included context

  Scenario: Sampling with model preferences
    Given an MCP server with sampling capability
    When the server sends a sampling/createMessage request
    And the request includes model preferences
    Then the client should consider the model preferences
    And the client should select an appropriate model
    And the client should respond with a completion
    And the response should include the selected model name

  Scenario: Sampling with image content
    Given an MCP server with sampling capability
    When the server sends a sampling/createMessage request
    And the request includes a message with image content
    Then the client should process the sampling request with the image
    And the client should respond with a completion
    And the completion should reflect awareness of the image content

  Scenario: Sampling with stop sequences
    Given an MCP server with sampling capability
    When the server sends a sampling/createMessage request
    And the request includes stop sequences
    And the LLM generates text containing a stop sequence
    Then the client should stop generation at the stop sequence
    And the client should respond with the partial completion
    And the stopReason should indicate the sequence was encountered

  Scenario: Sampling with user modifications
    Given an MCP server with sampling capability
    When the server sends a sampling/createMessage request
    And the user modifies the request before processing
    Then the client should use the modified request
    And the client should respond with a completion
    And the completion should reflect the user's modifications
