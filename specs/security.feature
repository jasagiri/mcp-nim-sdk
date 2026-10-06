Feature: The JSON Schema validator against hostile input and hostile schemas
  As an operator whose server checks tool arguments, and a client that checks
  results against a schema the server supplied
  I want the validator to stay within bounded stack, time and memory
  So that one request or one schema cannot take the process down

  @spec:MCP-SEC-SCHEMA-1
  Scenario: A plain pattern is checked against text of any length the transport allows
    Given a pattern such as ^[a-z]+$ and 4 MiB of text
    When the text is matched
    Then the answer is given and the process neither crashes nor exhausts its stack

  @spec:MCP-SEC-SCHEMA-2
  Scenario: A pattern that backtracks catastrophically is answered in time proportional to the text
    Given patterns such as (a|a)*$, (a+)+$ and (a|aa)+$ and 100000 characters of text
    When the text is matched
    Then each answer is the one the pattern means, and a match that exceeds its step budget raises a limit error instead of a verdict

  @spec:MCP-SEC-SCHEMA-3
  Scenario: A pattern that asks for an enormous program is refused
    Given a pattern with a huge repetition count, nested repetitions, too many characters or too many nested groups
    When it is compiled
    Then a limit error is raised, and a caller can raise the limit
