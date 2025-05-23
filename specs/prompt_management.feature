Feature: MCP Prompt Management
  As a MCP Server implementer
  I want to register and manage prompt templates
  So that clients can use standardized prompts for LLM interactions

  Background:
    Given I have a running MCP server with prompt capabilities
      | listChanged |
      | true        |

  Scenario: Registering a simple prompt type
    When I register a prompt type with the following properties
      | name              | description               | paramsSchema                                           |
      | "simple_question" | "A simple question prompt" | {"type": "object", "properties": {"question": {"type": "string"}}, "required": ["question"]} |
    Then the prompt type should be available in the prompt list via "prompts/list"
    And the prompt type definition should include the correct name, description, and schema
    And the client should be able to get the prompt messages via "prompts/get"

  Scenario: Registering multiple prompt types
    When I register the following prompt types
      | name              | description               |
      | "simple_question" | "A simple question prompt" |
      | "summarization"   | "A summarization prompt"   |
      | "comparison"      | "A comparison prompt"      |
    Then all prompt types should be available in the prompt list
    And each prompt type should be independently retrievable
    And the prompt types should be returned with the correct metadata

  Scenario: Prompt parameter validation - valid parameters
    Given I have registered a prompt type with parameter schema
      | parameter | type     | required |
      | "question" | "string" | true     |
      | "context"  | "string" | false    |
    When a client sends valid parameters
      | parameter  | value                  |
      | "question" | "What is MCP?"         |
      | "context"  | "Model Context Protocol" |
    Then the parameters should pass validation
    And the prompt messages should be generated successfully

  Scenario: Prompt parameter validation - missing required parameter
    Given I have registered a prompt type with parameter schema
      | parameter | type     | required |
      | "question" | "string" | true     |
      | "context"  | "string" | true     |
    When a client sends parameters missing a required parameter
      | parameter  | value          |
      | "question" | "What is MCP?" |
    Then the validation should fail
    And the error should indicate the missing parameter

  Scenario: Prompt parameter validation - type mismatch
    Given I have registered a prompt type with parameter schema
      | parameter    | type      | required |
      | "question"   | "string"  | true     |
      | "max_length" | "integer" | true     |
    When a client sends parameters with wrong types
      | parameter    | value          |
      | "question"   | "What is MCP?" |
      | "max_length" | "100"          |
    Then the validation should fail
    And the error should indicate the type mismatch

  Scenario: Prompt list change notifications
    Given I have registered several prompt types
    When I add a new prompt type to the registry
    Then the server should send a "notifications/prompts/list_changed" notification
    And the updated prompt list should include the new prompt type

  Scenario: Complex prompt generation
    Given I have registered a complex prompt type with multiple parameters
    When a client requests prompt messages with various parameters
    Then the generated prompt messages should reflect the provided parameters
    And the messages should be formatted according to the prompt type design
