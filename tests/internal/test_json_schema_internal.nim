## JSON Schema as MCP uses it (2025-11-25, basic/index "JSON Schema Usage"):
## 2020-12 unless `$schema` says otherwise, and a schema that cannot be
## checked is reported instead of passing.

import std/[unittest, json]
import jsonschema/json_schema
import jsonschema/json_schema_regex

proc violations(schema, instance: string): seq[SchemaViolation] =
  validate(parseJson(schema), parseJson(instance))

proc conforms(schema, instance: string): bool =
  violations(schema, instance).len == 0


suite "regular expressions of patterns":

  test "Given quantifiers, when matched, then greedy and lazy forms both find a match":
    check compileRegex("^a{2,3}$").isMatch("aaa")
    check not compileRegex("^a{2,3}$").isMatch("aaaa")
    check compileRegex("^a+?b$").isMatch("aaab")
    check compileRegex("^(ab)*$").isMatch("ababab")

  test "Given classes and escapes, when matched, then they follow ECMA-262":
    check compileRegex("^[^0-9]+$").isMatch("abc")
    check not compileRegex("^[^0-9]+$").isMatch("a1")
    check compileRegex("^\\w+\\s\\S+$").isMatch("ab cd")
    check compileRegex("\\bfoo\\b").isMatch("a foo b")
    check not compileRegex("\\bfoo\\b").isMatch("afoob")
    check compileRegex("^\\u0041\\x42$").isMatch("AB")
    check compileRegex("^[\\d-]+$").isMatch("1-2")

  test "Given an empty-matching loop, when matched, then it terminates":
    check compileRegex("^(a*)*$").isMatch("aaa")
    check not compileRegex("^(a*)*$").isMatch("aab")

  test "Given Unicode property escapes, when compiled, then they are rejected":
    expect RegexError:
      discard compileRegex("\\p{L}")

proc invalidSchemaOf(schema, instance: string): ref InvalidSchemaError =
  ## The error that validating raises, nil when it raises none.
  try:
    discard violations(schema, instance)
  except InvalidSchemaError as e:
    return e

proc constOf(value: JsonNode): JsonNode =
  result = newJObject()
  result["const"] = value

proc areDistinct(a, b: string): bool =
  ## Whether `uniqueItems` accepts the two values as different.
  conforms("""{"uniqueItems": true}""", "[" & a & ", " & b & "]")

const draft07 = """"$schema": "http://json-schema.org/draft-07/schema#" """



proc patternSchema(pattern: string): JsonNode =
  result = newJObject()
  result["pattern"] = %pattern

proc matches(pattern, text: string): bool =
  ## Whether `text` conforms to a schema whose `pattern` is `pattern`.
  validate(patternSchema(pattern), %text).len == 0

proc compiles(pattern: string) =
  ## Raises InvalidSchemaError (SchemaLimitError for a limit) when `pattern` is refused.
  discard validate(patternSchema(pattern), %"")

proc refusal(pattern: string): string =
  ## The message of the InvalidSchemaError a pattern is refused with; "" if it compiles.
  try:
    compiles(pattern)
  except InvalidSchemaError as e:
    result = e.msg

