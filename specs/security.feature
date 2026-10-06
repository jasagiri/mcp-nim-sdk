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

  @spec:MCP-SEC-SCHEMA-6
  Scenario: A length or size limit written as a number with no fractional part is read as that integer
    Given minLength, maxLength, minItems, maxItems, minProperties, maxProperties, minContains or maxContains with the value 5.0
    When an instance is validated
    Then the limit applies as 5 does, and a value that is negative, fractional or not a number is an invalid schema, never read as 0

  @spec:MCP-SEC-SCHEMA-7
  Scenario: uniqueItems takes time proportional to the items and follows JSON equality
    Given an array of 100000 distinct objects, and arrays of values that are or only look equal such as 1 and 1.0, objects with keys in another order, [1, 2] and [2, 1], or 9007199254740993 and 9007199254740992
    When uniqueItems is checked
    Then the answer is immediate, equal values are reported with the index of the first copy, and values that differ are not

  @spec:MCP-SEC-SCHEMA-8
  Scenario: A malformed keyword is reported, never skipped, and no schema makes the validator raise something else
    Given dependentRequired or draft-07 dependencies that do not hold lists of names, a $ref index that overflows or is out of range, or a multipleOf whose quotient a double cannot hold
    When an instance is validated
    Then InvalidSchemaError (or SchemaLimitError for the quotient) is raised, and the instance is not reported as conforming
Feature: Security of the HTTP server transport
  As an operator who puts an MCP server behind authorization
  I want every endpoint of the transport to be protected, and a client to be bound to its own session
  So that one caller cannot read, answer, cancel or starve another's

  Specification: Authorization (2025-03-26 and later, basic/authorization:
  "Token Requirements": every HTTP request from client to server MUST carry
  the token, whether or not they are part of the same logical session) and
  Streamable HTTP, "Security Warning" (2025-11-25, 2026-07-28). Findings:
  build/SECURITY_FINDINGS.md C1, M1, M2, M6, L5, L6.

  @spec:MCP-SEC-HTTP-1
  Scenario: A transport with authorization protects every MCP endpoint
    Given a transport with a token verifier
    When a request without a token arrives at the MCP path, at the HTTP+SSE event stream path or at the HTTP+SSE messages path
    Then each is answered 401 and nothing reaches the MCP server
    And a request with a good token reaches the server as that principal
    And a fixed document and the authorization metadata are still served without a token
