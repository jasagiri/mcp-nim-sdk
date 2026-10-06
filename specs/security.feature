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

  @spec:MCP-SEC-SCHEMA-4
  Scenario: A $ref that leads back to itself without reading further into the instance is an invalid schema
    Given schemas such as {"$ref": "#"}, two $refs that point at each other, or a $ref cycle through allOf
    When an instance is validated
    Then InvalidSchemaError is raised, while a recursive schema that reads deeper into the instance (a tree) is still validated

  @spec:MCP-SEC-SCHEMA-5
  Scenario: Validation stops at its depth, work and regular expression limits instead of exhausting the process
    Given an instance or a schema nested beyond the depth limit, $refs that double at every level, or matches that add up above the regex budget
    When an instance is validated
    Then SchemaLimitError (an InvalidSchemaError) is raised, never a verdict, and the caller can change the limits
