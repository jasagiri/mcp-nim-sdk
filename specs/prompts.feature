Feature: Prompts
  As an application that offers users ready-made prompts
  I want a server to list its prompts and expand one with arguments
  So that a user picks a prompt and the model receives its messages

  Specification: server/prompts in every version.

  @spec:MCP-PROMPTS-1 @feature:ftPrompts
  Scenario: A server lists its prompts and expands one
    Given a server that declared the prompts capability and has a prompt
    When a client sends prompts/list and prompts/get with the prompt's name and arguments
    Then the list result has a prompts array whose entries carry a name
    And the get result has the messages the handler built, each with a role and content, and the handler was given the arguments

  @spec:MCP-PROMPTS-2 @feature:ftPrompts
  Scenario: A client lists prompts and gets one
    Given a server with prompts
    When the client lists them and gets one with arguments
    Then it reads each prompt's arguments, sends the argument values as strings, and reads the messages
    And without arguments the request carries no arguments key

  @spec:MCP-PROMPTS-3 @feature:ftPrompts
  Scenario: A server without the prompts capability does not serve prompts
    Given a server that did not declare the prompts capability
    When a client sends prompts/list or prompts/get
    Then the answer is method not found

  @spec:MCP-PROMPTS-4 @feature:ftPrompts
  Scenario: An unknown prompt or a missing required argument is invalid params
    Given a server whose handler refuses a prompt name or a missing argument with invalid params
    When a client sends prompts/get for an unknown name or without a required argument
    Then the answer is the error -32602
