Feature: MCP Sampling Support
  As a MCP Server implementer
  I want to request LLM sampling through the client
  So that I can use the client's LLM capabilities in my application

  Background:
    Given the MCP protocol version is "2024-11-26"
    And a valid message serialization format using JSON-RPC 2.0
    And I have a running MCP server with sampling capabilities
    And the client supports sampling

  Scenario: Basic text completion request
    When I send a sampling request with a simple text message
      """json
      {
        "messages": [
          {
            "role": "user",
            "content": {
              "type": "text",
              "text": "Hello, how are you today?"
            }
          }
        ],
        "maxTokens": 1000
      }
      """
    Then the client should receive the sampling request via "sampling/createMessage"
    And the client should process the request and sample from an LLM
    And the server should receive a response with:
      | field       | description                      |
      | "role"      | Set to "assistant"               |
      | "content"   | Contains the generated text      |
      | "model"     | Identifies the model used        |
      | "stopReason"| Indicates why generation stopped |

  Scenario: Multi-turn conversation sampling
    Given I have a conversation history with multiple turns:
      | role        | content                        |
      | "user"      | "What is the capital of France?"|
      | "assistant" | "The capital of France is Paris."|
      | "user"      | "What about Germany?"          |
    When I send a sampling request with this conversation history
    Then the client should receive all conversation messages in correct order
    And the LLM should understand the conversation context
    And respond with information about Germany's capital
    And maintain conversational coherence

  Scenario: Sampling with system prompt
    When I send a sampling request with a system prompt
      """json
      {
        "messages": [
          {
            "role": "user",
            "content": {
              "type": "text",
              "text": "Write a short poem"
            }
          }
        ],
        "systemPrompt": "You are a professional poet who writes in a concise haiku style",
        "maxTokens": 1000
      }
      """
    Then the client should receive the request with the system prompt
    And the LLM should adopt the persona defined in the system prompt
    And the response should reflect the haiku style guidelines
    And be formatted appropriately

  Scenario: Sampling with model preferences
    When I send a sampling request with specific model preferences
      """json
      {
        "messages": [
          {
            "role": "user",
            "content": {
              "type": "text",
              "text": "Explain quantum computing"
            }
          }
        ],
        "modelPreferences": {
          "hints": [
            {"name": "claude-3-opus"},
            {"name": "claude-3-sonnet"}
          ],
          "costPriority": 0.2,
          "speedPriority": 0.3,
          "intelligencePriority": 0.9
        },
        "maxTokens": 2000
      }
      """
    Then the client should consider the model preference hints
    And prioritize intelligence over cost and speed
    And select an appropriate model based on the preferences
    And return the selected model name in the response

  Scenario: Sampling with context inclusion
    Given I have resources containing relevant context information
    When I send a sampling request with context inclusion "thisServer"
      """json
      {
        "messages": [
          {
            "role": "user",
            "content": {
              "type": "text",
              "text": "Summarize the project documentation"
            }
          }
        ],
        "includeContext": "thisServer",
        "maxTokens": 1500
      }
      """
    Then the client should request context from the server
    And merge the context with the user message
    And the LLM should generate a response based on the context
    And the response should be relevant to the server's resources

  Scenario: Sampling with temperature and randomness control
    When I send sampling requests with different temperature settings
      | temperature | request                          | expectation                      |
      | 0.0         | "List 5 capital cities"          | Deterministic, consistent output |
      | 0.7         | "Write a creative story opening" | Some creativity and variation    |
      | 1.0         | "Generate random words"          | Maximum randomness and variation |
    Then each response should exhibit appropriate levels of randomness
    And lower temperatures should produce more predictable outputs
    And higher temperatures should produce more varied outputs

  Scenario: Sampling with stop sequences
    When I send a sampling request with stop sequences
      """json
      {
        "messages": [
          {
            "role": "user",
            "content": {
              "type": "text",
              "text": "Count from 1 to 10"
            }
          }
        ],
        "stopSequences": ["5", "STOP"],
        "maxTokens": 1000
      }
      """
    Then the LLM should stop generating when it produces one of the stop sequences
    And the response should include the stopReason "stopSequence"
    And the content should be truncated appropriately
    And the client should not include the stop sequence in the response

  Scenario: Sampling with multimodal content
    When I send a sampling request with mixed text and image content
      """json
      {
        "messages": [
          {
            "role": "user",
            "content": [
              {
                "type": "text",
                "text": "What's in this image?"
              },
              {
                "type": "image",
                "data": "base64encodedimagedata...",
                "mimeType": "image/jpeg"
              }
            ]
          }
        ],
        "maxTokens": 1000
      }
      """
    Then the client should process both the text and image content
    And forward them to a multimodal LLM if available
    And return a response describing the image
    And handle the response appropriately

  Scenario: Error handling in sampling
    When I send sampling requests with various error conditions
      | error_type         | request_issue                       |
      | "invalid_format"   | Missing required 'messages' field   |
      | "token_limit"      | Excessive maxTokens value           |
      | "safety_filter"    | Content that violates safety policy |
      | "timeout"          | Request times out during processing |
    Then each error should be properly caught and handled
    And appropriate error information should be returned
    And the server should handle the errors gracefully
    And maintain protocol stability

  Scenario: Sampling with streaming support
    When I send a sampling request with streaming enabled
      """json
      {
        "messages": [
          {
            "role": "user",
            "content": {
              "type": "text",
              "text": "Tell me a long story"
            }
          }
        ],
        "maxTokens": 1000,
        "stream": true
      }
      """
    Then the client should process the request in streaming mode
    And the response should be returned in multiple chunks
    And each chunk should build upon the previous content
    And the final chunk should indicate completion
    And the server should reassemble the complete response