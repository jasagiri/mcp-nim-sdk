## JSON Schema as MCP uses it (2025-11-25, basic/index "JSON Schema Usage"):
## 2020-12 unless `$schema` says otherwise, and a schema that cannot be
## checked is reported instead of passing.

import std/[unittest, json, strutils]
import jsonschema/json_schema
import jsonschema/json_schema_regex

proc violations(schema, instance: string): seq[SchemaViolation] =
  validate(parseJson(schema), parseJson(instance))

proc conforms(schema, instance: string): bool =
  violations(schema, instance).len == 0

suite "JSON Schema dialects":

  test "Given a schema without $schema, when its dialect is asked, then it is 2020-12":
    check dialectOf(parseJson("""{"type": "object"}""")) == sdDraft202012

  test "Given $schema naming 2020-12, when its dialect is asked, then it is 2020-12":
    check dialectOf(parseJson("""{"$schema": "https://json-schema.org/draft/2020-12/schema"}""")) ==
      sdDraft202012

  test "Given $schema naming draft-07 with or without the empty fragment, when its dialect is asked, then it is draft-07":
    check dialectOf(parseJson("""{"$schema": "http://json-schema.org/draft-07/schema#"}""")) == sdDraft07
    check dialectOf(parseJson("""{"$schema": "http://json-schema.org/draft-07/schema"}""")) == sdDraft07

  test "Given $schema naming an unknown dialect, when an instance is validated, then the dialect is reported unsupported":
    expect UnsupportedDialectError:
      discard violations("""{"$schema": "https://example.com/own-dialect", "type": "object"}""", "{}")

  test "Given $schema that is not a string, when an instance is validated, then the schema is invalid":
    expect InvalidSchemaError:
      discard violations("""{"$schema": 7}""", "{}")

  test "Given a prefixItems schema, when validated as 2020-12 and as draft-07, then only 2020-12 reads it":
    let schema = """{"prefixItems": [{"type": "string"}]}"""
    check not conforms(schema, "[1]")
    check conforms("""{"$schema": "http://json-schema.org/draft-07/schema#", "prefixItems": [{"type": "string"}]}""", "[1]")

  test "Given an array items in draft-07, when validated, then the items are positional":
    let schema = """{"$schema": "http://json-schema.org/draft-07/schema#",
                      "items": [{"type": "string"}, {"type": "integer"}], "additionalItems": false}"""
    check conforms(schema, """["a", 1]""")
    check not conforms(schema, """["a", "b"]""")
    check not conforms(schema, """["a", 1, 2]""")

suite "JSON Schema keywords":

  test "Given type, when instances of each JSON type are validated, then only the named type conforms":
    check conforms("""{"type": "string"}""", "\"a\"")
    check not conforms("""{"type": "string"}""", "1")
    check conforms("""{"type": "integer"}""", "3")
    check conforms("""{"type": "integer"}""", "3.0")
    check not conforms("""{"type": "integer"}""", "3.5")
    check conforms("""{"type": "number"}""", "3")
    check conforms("""{"type": ["null", "boolean"]}""", "null")
    check not conforms("""{"type": ["null", "boolean"]}""", "0")
    check conforms("""{"type": "array"}""", "[]")
    check conforms("""{"type": "object"}""", "{}")

  test "Given a type that does not exist, when validated, then the schema is invalid":
    expect InvalidSchemaError:
      discard violations("""{"type": "text"}""", "1")

  test "Given required and properties, when an object lacks a property or has a wrong one, then each is reported with its path":
    let schema = """{"type": "object", "required": ["a", "b"],
                      "properties": {"a": {"type": "string"}, "b": {"type": "integer"}}}"""
    check conforms(schema, """{"a": "x", "b": 1}""")
    let missing = violations(schema, """{"a": "x"}""")
    check missing.len == 1
    check "'b'" in missing[0].message
    let wrong = violations(schema, """{"a": 5, "b": 1}""")
    check wrong.len == 1
    check wrong[0].path == "/a"

  test "Given additionalProperties false, when an extra property is present, then it is reported":
    let schema = """{"properties": {"a": {}}, "additionalProperties": false}"""
    check conforms(schema, """{"a": 1}""")
    check not conforms(schema, """{"a": 1, "z": 2}""")

  test "Given additionalProperties as a schema, when an extra property has the wrong type, then it is reported":
    let schema = """{"properties": {"a": {}}, "additionalProperties": {"type": "integer"}}"""
    check conforms(schema, """{"a": "x", "z": 2}""")
    check not conforms(schema, """{"a": "x", "z": "y"}""")

  test "Given enum and const, when a value differs, then it is reported; 1 and 1.0 are equal":
    check conforms("""{"enum": ["a", 1, null]}""", "1.0")
    check not conforms("""{"enum": ["a", 1]}""", "\"b\"")
    check conforms("""{"const": {"k": [1, 2]}}""", """{"k": [1, 2.0]}""")
    check not conforms("""{"const": 1}""", "2")

  test "Given number limits, when values sit on each side of them, then the bounds are enforced":
    check conforms("""{"minimum": 1, "maximum": 3}""", "1")
    check conforms("""{"minimum": 1, "maximum": 3}""", "3")
    check not conforms("""{"minimum": 1}""", "0")
    check not conforms("""{"maximum": 3}""", "4")
    check not conforms("""{"exclusiveMinimum": 1}""", "1")
    check not conforms("""{"exclusiveMaximum": 3}""", "3")
    check conforms("""{"multipleOf": 0.5}""", "2.5")
    check not conforms("""{"multipleOf": 0.5}""", "2.3")

  test "Given string limits, when lengths are counted, then code points count, not bytes":
    check conforms("""{"maxLength": 2}""", "\"日本\"")
    check not conforms("""{"maxLength": 2}""", "\"日本語\"")
    check not conforms("""{"minLength": 3}""", "\"ab\"")

  test "Given pattern, when it matches anywhere in the string, then the value conforms":
    check conforms("""{"pattern": "^[a-z]+-\\d{2,3}$"}""", "\"abc-12\"")
    check not conforms("""{"pattern": "^[a-z]+-\\d{2,3}$"}""", "\"abc-1\"")
    check conforms("""{"pattern": "b+"}""", "\"aabba\"")
    check conforms("""{"pattern": "^(?:cat|dog)s?$"}""", "\"dogs\"")
    check not conforms("""{"pattern": "^(?!x)."}""", "\"xa\"")

  test "Given a malformed or unsupported pattern, when validated, then the schema is invalid":
    expect InvalidSchemaError:
      discard violations("""{"pattern": "(unclosed"}""", "\"a\"")
    expect InvalidSchemaError:
      discard violations("""{"pattern": "(a)\\1"}""", "\"aa\"")

  test "Given array keywords, when lengths, uniqueness and contains are violated, then each is reported":
    check not conforms("""{"minItems": 2}""", "[1]")
    check not conforms("""{"maxItems": 1}""", "[1, 2]")
    check not conforms("""{"uniqueItems": true}""", "[1, 1.0]")
    check conforms("""{"uniqueItems": true}""", "[1, 2]")
    check conforms("""{"contains": {"type": "string"}}""", """[1, "a"]""")
    check not conforms("""{"contains": {"type": "string"}}""", "[1]")
    check not conforms("""{"contains": {"type": "string"}, "minContains": 2}""", """["a"]""")
    check not conforms("""{"contains": {"type": "string"}, "maxContains": 1}""", """["a", "b"]""")

  test "Given items and prefixItems, when elements break them, then the failing index is in the path":
    let schema = """{"prefixItems": [{"type": "string"}], "items": {"type": "integer"}}"""
    check conforms(schema, """["a", 1, 2]""")
    let found = violations(schema, """["a", 1, "x"]""")
    check found.len == 1
    check found[0].path == "/2"

  test "Given combinators, when instances are tried, then allOf anyOf oneOf and not behave":
    check not conforms("""{"allOf": [{"type": "integer"}, {"minimum": 5}]}""", "3")
    check conforms("""{"anyOf": [{"type": "string"}, {"type": "integer"}]}""", "3")
    check not conforms("""{"anyOf": [{"type": "string"}, {"type": "integer"}]}""", "null")
    check conforms("""{"oneOf": [{"type": "integer"}, {"minimum": 5}]}""", "3")
    check not conforms("""{"oneOf": [{"type": "integer"}, {"minimum": 5}]}""", "7")
    check not conforms("""{"not": {"type": "string"}}""", "\"a\"")

  test "Given if then else, when the condition holds or not, then the matching branch applies":
    let schema = """{"if": {"properties": {"k": {"const": 1}}, "required": ["k"]},
                      "then": {"required": ["a"]}, "else": {"required": ["b"]}}"""
    check conforms(schema, """{"k": 1, "a": 0}""")
    check not conforms(schema, """{"k": 1}""")
    check conforms(schema, """{"b": 0}""")
    check not conforms(schema, """{"k": 2}""")

  test "Given dependentRequired and dependentSchemas, when the trigger is present, then they apply":
    check not conforms("""{"dependentRequired": {"a": ["b"]}}""", """{"a": 1}""")
    check conforms("""{"dependentRequired": {"a": ["b"]}}""", """{"c": 1}""")
    check not conforms("""{"dependentSchemas": {"a": {"required": ["b"]}}}""", """{"a": 1}""")

  test "Given propertyNames and patternProperties, when names break them, then they are reported":
    check not conforms("""{"propertyNames": {"maxLength": 2}}""", """{"abc": 1}""")
    check not conforms("""{"patternProperties": {"^n_": {"type": "integer"}}}""", """{"n_a": "x"}""")
    check conforms("""{"patternProperties": {"^n_": {"type": "integer"}}}""", """{"n_a": 1, "other": "x"}""")

  test "Given a local $ref, when it points into $defs or at the root, then the referenced schema applies":
    let schema = """{"$defs": {"id": {"type": "integer", "minimum": 1}},
                      "properties": {"a": {"$ref": "#/$defs/id"}, "child": {"$ref": "#"}}}"""
    check conforms(schema, """{"a": 2, "child": {"a": 3}}""")
    check not conforms(schema, """{"a": 0}""")
    check not conforms(schema, """{"child": {"a": 0}}""")

  test "Given a $ref that leaves the document or points at nothing, when validated, then it is reported":
    expect UnsupportedKeywordError:
      discard violations("""{"$ref": "https://example.com/other.json"}""", "1")
    expect InvalidSchemaError:
      discard violations("""{"$ref": "#/$defs/missing"}""", "1")

  test "Given a keyword that is not implemented, when validated, then it is reported, not skipped":
    expect UnsupportedKeywordError:
      discard violations("""{"unevaluatedProperties": false}""", "{}")

  test "Given the boolean schemas, when validated, then true accepts and false rejects everything":
    check conforms("true", "1")
    check not conforms("false", "1")

  test "Given format and annotation keywords, when validated, then they assert nothing":
    check conforms("""{"type": "string", "format": "email", "title": "t", "description": "d"}""", "\"nope\"")

  test "Given several violations, when described, then each is listed with its path":
    let found = violations("""{"properties": {"a": {"type": "string"}, "b": {"type": "string"}}}""",
                           """{"a": 1, "b": 2}""")
    check found.len == 2
    check "/a" in describe(found) and "/b" in describe(found)

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

suite "JSON Schema keywords (mutation review, g2h-js-a)":

  test "Given a $schema that only contains a name after a leading #, when validated, then the dialect is unsupported":
    expect UnsupportedDialectError:
      discard violations("""{"$schema": "#https://json-schema.org/draft/2020-12/schema"}""", "{}")

  test "Given a keyword of the wrong JSON type, when validated, then the schema is invalid":
    for (keyword, bad, instance) in [("minimum", "\"1\"", "1"), ("exclusiveMaximum", "true", "1"),
                                     ("pattern", "5", "\"a\""), ("uniqueItems", "1", "[]"),
                                     ("properties", "[]", "{}"), ("allOf", "{}", "1")]:
      check invalidSchemaOf("{\"" & keyword & "\": " & bad & "}", instance) != nil

  test "Given a type list with a member that is not a string, when a matching instance is validated, then the schema is invalid":
    check invalidSchemaOf("""{"type": ["string", 5]}""", "\"x\"") != nil

  test "Given an infinite number, when validated against integer and number, then it is a number but no integer":
    check validate(parseJson("""{"type": "integer"}"""), newJFloat(Inf)).len == 1
    check validate(parseJson("""{"type": "number"}"""), newJFloat(Inf)).len == 0

  test "Given a count keyword, when it is 0, 2.0, 2.5 or negative, then 0 and 2.0 are read and the others are invalid":
    check conforms("""{"minLength": 0}""", "\"\"")
    check conforms("""{"maxLength": 2.0}""", "\"ab\"")
    check not conforms("""{"maxLength": 2.0}""", "\"abc\"")
    check invalidSchemaOf("""{"minLength": -1}""", "\"\"") != nil
    check invalidSchemaOf("""{"minLength": 2.5}""", "\"\"") != nil
    check invalidSchemaOf("""{"maxLength": -1.0}""", "\"\"") != nil

  test "Given const arrays, when the instance differs in length or in an item, then it does not conform":
    check conforms("""{"const": [1, 2]}""", "[1, 2]")
    check not conforms("""{"const": [1]}""", "[1, 2]")
    check not conforms("""{"const": [1, 2]}""", "[1]")
    check not conforms("""{"const": [1, 2]}""", "[1, 3]")

  test "Given const objects, when the instance differs in size, in a key or in a value, then it does not conform":
    check conforms("""{"const": {"a": 1, "b": 2}}""", """{"b": 2, "a": 1}""")
    check not conforms("""{"const": {"a": 1}}""", """{"a": 1, "b": 2}""")
    check not conforms("""{"const": {"a": 1, "b": 2}}""", """{"a": 1}""")
    check not conforms("""{"const": {"a": 1}}""", """{"b": 1}""")
    check not conforms("""{"const": {"a": 1}}""", """{"a": 2}""")

  test "Given 1 and 1.0, when compared by const and enum in either direction, then they are the same number":
    check conforms("""{"const": 1.0}""", "1")
    check conforms("""{"const": 1}""", "1.0")
    check conforms("""{"const": [1.0]}""", "[1]")
    check conforms("""{"enum": [2, 1.0]}""", "1")
    check not conforms("""{"const": 1.0}""", "2")
    check not conforms("""{"const": 1}""", "1.5")

  test "Given integers at the edge of 64 bits, when compared with doubles, then equal values match and neighbours do not":
    check validate(constOf(newJInt(low(int64))), newJFloat(-9223372036854775808.0)).len == 0
    check validate(constOf(newJFloat(-9223372036854775808.0)), newJInt(low(int64))).len == 0
    check validate(constOf(newJInt(high(int64))), newJFloat(9223372036854775808.0)).len == 1
    check validate(constOf(newJFloat(9223372036854775808.0)), newJInt(high(int64))).len == 1
    check validate(constOf(newJFloat(9223372036854775808.0)), newJFloat(9223372036854775808.0)).len == 0

  test "Given uniqueItems, when two items are the same value however spelled, then the array does not conform":
    check not conforms("""{"uniqueItems": true}""", "[1, 1.0]")
    check not conforms("""{"uniqueItems": true}""", """[{"a": 1, "b": 2}, {"b": 2, "a": 1}]""")
    check not conforms("""{"uniqueItems": true}""", "[[1, [true]], [1, [true]]]")
    check conforms("""{"uniqueItems": true}""", """[1, "1", true, null, [1], {"1": 1}]""")
    check conforms("""{"uniqueItems": true}""", "[[1, 2], [2, 1]]")
    check conforms("""{"uniqueItems": false}""", "[1, 1]")

  test "Given uniqueItems, when items of different type or content could be told apart only by a part of their text, then they are distinct":
    # Each pair is two different values; a comparison that leaves one part of the
    # value out of its key would find them equal.
    check areDistinct("[null]", "[]")
    check areDistinct("true", "false")
    check areDistinct("\"a\"", "\"b\"")
    check areDistinct("""["x", "y"]""", """["xs:y"]""")
    check areDistinct("""["2", 1234567890]""", """["d1234567890;"]""")
    check areDistinct("[[], []]", "[[[]]]")
    check areDistinct("""{"a": 1}""", """{"b": 1}""")
    check areDistinct("""{"a": {"b": 1}, "c": 2}""", """{"a": {"b": 1, "c": 2}}""")
    check areDistinct("""{"a": 1, "b": 2}""", """{"ad1;:b": 2}""")
    check areDistinct("""{"a": 1, "ks9:0123456": 2}""", """{"a": 11, "k": "0123456d2"}""")
    check areDistinct("""{"1": null, "b": "abcden"}""", """{"n1bs6:abcde": null}""")

  test "Given a $ref into an array, when validated, then the element is the target":
    let schema = """{"$defs": {"list": [{"type": "string"}, {"type": "integer"}]}, "$ref": "#/$defs/list/1"}"""
    check conforms(schema, "5")
    check not conforms(schema, "\"x\"")
    check conforms("""{"$defs": {"a": {"0": {"type": "integer"}}}, "$ref": "#/$defs/a/0"}""", "5")

  test "Given a $ref whose index step names nothing, when validated, then the schema is invalid":
    check invalidSchemaOf("""{"$defs": {"a": {"x": 1}}, "$ref": "#/$defs/a/0"}""", "5") != nil
    check invalidSchemaOf("""{"$defs": {"a": [true]}, "$ref": "#/$defs/a/"}""", "5") != nil
    check invalidSchemaOf("""{"$defs": {"a": [true]}, "$ref": "#/$defs/a/x"}""", "5") != nil

  test "Given a $ref that points at nothing inside a property, when an instance is validated, then the schema is invalid":
    check invalidSchemaOf("""{"properties": {"a": {"$ref": "#/nothing"}}}""", """{"a": {}}""") != nil
    check invalidSchemaOf("""{"properties": {"a": {"$ref": "#/$defs/nothing"}}, "$defs": {}}""", """{"a": {}}""") != nil

  test "Given a $ref that comes back to itself, when validated, then the schema is invalid and no limit is reported":
    for schema in ["""{"$ref": "#"}""", """{"$defs": {"a": {"$ref": "#/$defs/a"}}, "$ref": "#/$defs/a"}"""]:
      let error = invalidSchemaOf(schema, "1")
      check error != nil
      check not (error of SchemaLimitError)

  test "Given a $ref with sibling keywords, when validated, then 2020-12 applies them and draft-07 ignores them":
    check not conforms("""{"$defs": {"any": {}}, "$ref": "#/$defs/any", "type": "string"}""", "5")
    check conforms("""{"$defs": {"any": {}}, "$ref": "#/$defs/any", "type": "string"}""", "\"x\"")
    check conforms("{" & draft07 & """, "definitions": {"any": {}}, "$ref": "#/definitions/any", "type": "string"}""", "5")

  test "Given multipleOf, when the divisor is not above zero, then the schema is invalid and no limit is reported":
    for divisor in ["0", "-2", "0.0"]:
      let error = invalidSchemaOf("{\"multipleOf\": " & divisor & "}", "0")
      check error != nil
      check not (error of SchemaLimitError)
    check invalidSchemaOf("""{"multipleOf": -2}""", "4") != nil

  test "Given multipleOf with a decimal divisor, when the quotient carries rounding error, then the decimal multiples still conform":
    check conforms("""{"multipleOf": 0.01}""", "1234.56")
    check conforms("""{"multipleOf": 0.0001}""", "0.0075")
    check not conforms("""{"multipleOf": 0.0001}""", "0.00751")
    check conforms("""{"multipleOf": 2}""", "6")
    check not conforms("""{"multipleOf": 2}""", "7")
    check conforms("""{"multipleOf": 1.5}""", "4.5")

  test "Given minLength and maxLength, when the length is at, below or above the bound, then the bound itself conforms":
    check conforms("""{"minLength": 3}""", "\"abc\"")
    check not conforms("""{"minLength": 3}""", "\"ab\"")
    check conforms("""{"maxLength": 3}""", "\"abc\"")
    check not conforms("""{"maxLength": 3}""", "\"abcd\"")
    check conforms("""{"maxLength": 0}""", "\"\"")
    check not conforms("""{"maxLength": 0}""", "\"a\"")
    check not conforms("""{"minLength": 0, "maxLength": 0}""", "\"a\"")

  test "Given a string of multibyte characters, when its length is bounded, then characters are counted, not bytes":
    check conforms("""{"minLength": 3, "maxLength": 3}""", "\"日本語\"")
    check not conforms("""{"maxLength": 2}""", "\"日本語\"")
    check conforms("""{"maxLength": 1}""", "\"😀\"")

  test "Given minItems and maxItems, when the size is at the bound, then it conforms and one beyond does not":
    check conforms("""{"minItems": 2}""", "[1, 2]")
    check not conforms("""{"minItems": 2}""", "[1]")
    check conforms("""{"minItems": 0}""", "[]")
    check conforms("""{"maxItems": 2}""", "[1, 2]")
    check not conforms("""{"maxItems": 2}""", "[1, 2, 3]")
    check conforms("""{"maxItems": 0}""", "[]")
    check not conforms("""{"maxItems": 0}""", "[1]")

  test "Given contains with minContains and maxContains, when the number of matches is at or beyond a bound, then the bounds are inclusive":
    let one = """{"const": 1}"""
    check conforms("{\"contains\": " & one & ", \"minContains\": 0}", "[]")
    check conforms("{\"contains\": " & one & ", \"minContains\": 0}", "[2]")
    check not conforms("{\"contains\": " & one & "}", "[2]")
    check conforms("{\"contains\": " & one & ", \"minContains\": 2}", "[1, 1]")
    check not conforms("{\"contains\": " & one & ", \"minContains\": 2}", "[1, 2]")
    check conforms("{\"contains\": " & one & ", \"maxContains\": 2}", "[1, 1, 2]")
    check not conforms("{\"contains\": " & one & ", \"maxContains\": 2}", "[1, 1, 1]")
    check not conforms("{\"contains\": " & one & ", \"maxContains\": 0}", "[1]")
    check not conforms("{\"contains\": " & one & ", \"maxContains\": 0}", "[2]")

  test "Given minContains or maxContains without contains, or in draft-07, when validated, then they assert nothing":
    check conforms("""{"maxContains": 0}""", "[1]")
    check conforms("""{"minContains": 5}""", "[1]")
    check conforms("{" & draft07 & """, "contains": {"const": 1}, "minContains": 2}""", "[1]")
    check conforms("{" & draft07 & """, "contains": {"const": 1}, "maxContains": 1}""", "[1, 1]")

  test "Given minProperties and maxProperties, when the size is at the bound, then it conforms and one beyond does not":
    check conforms("""{"minProperties": 1}""", """{"a": 1}""")
    check conforms("""{"minProperties": 1}""", """{"a": 1, "b": 2}""")
    check not conforms("""{"minProperties": 1}""", "{}")
    check conforms("""{"minProperties": 0}""", "{}")
    check conforms("""{"maxProperties": 1}""", """{"a": 1}""")
    check not conforms("""{"maxProperties": 1}""", """{"a": 1, "b": 2}""")
    check conforms("""{"maxProperties": 0}""", "{}")
    check not conforms("""{"maxProperties": 0}""", """{"a": 1}""")

  test "Given required with a member that is not a string, when validated, then the schema is invalid":
    check invalidSchemaOf("""{"required": [5]}""", "{}") != nil
    check invalidSchemaOf("""{"required": ["a", 5]}""", """{"a": 1}""") != nil

  test "Given patternProperties, when a property matches a pattern, then additionalProperties does not apply to it":
    let schema = """{"patternProperties": {"^a": {"type": "integer"}}, "additionalProperties": false}"""
    check conforms(schema, """{"ab": 1}""")
    check not conforms(schema, """{"ab": "x"}""")
    check not conforms(schema, """{"b": 1}""")

  test "Given dependencies in 2020-12, when validated, then they assert nothing":
    check conforms("""{"dependencies": {"a": ["b"]}}""", """{"a": 1}""")

  test "Given draft-07 dependencies as a list of names, when validated, then a present key demands the others":
    let schema = "{" & draft07 & """, "dependencies": {"a": ["b"]}}"""
    check conforms(schema, "{}")
    check conforms(schema, """{"b": 1}""")
    check conforms(schema, """{"a": 1, "b": 2}""")
    check not conforms(schema, """{"a": 1}""")
    check "requires property 'b'" in describe(violations(schema, """{"a": 1}"""))

  test "Given a $ref whose array index has a leading zero, when validated, then the schema is invalid (RFC 6901)":
    check conforms("""{"$defs": {"a": [{"type": "integer"}]}, "$ref": "#/$defs/a/0"}""", "5")
    for index in ["00", "01", "000000000"]:
      check invalidSchemaOf("{\"$defs\": {\"a\": [true, true]}, \"$ref\": \"#/$defs/a/" & index & "\"}", "5") != nil


import std/unicode

proc matches(pattern, text: string): bool =
  compileRegex(pattern).isMatch(text)

proc refusal(pattern: string): string =
  ## The message of the RegexError a pattern is refused with; "" if it compiles.
  try:
    discard compileRegex(pattern)
  except RegexError as e:
    result = e.msg

suite "regular expressions of patterns (mutation review, g2h-js-b)":

  test "Given the negated shorthands, when matched at the edges of their sets, then members are refused and the neighbours accepted":
    for member in ["0", "5", "9"]:
      check not matches("^\\D$", member)
    for outside in ["/", ":", "a", "\x00", "あ", $Rune(0x10FFFF)]:
      check matches("^\\D$", outside)
    for member in ["0", "9", "A", "Z", "_", "a", "z"]:
      check not matches("^\\W$", member)
    for outside in ["/", ":", "@", "[", "^", "`", "{", "\x00", "あ", $Rune(0x10FFFF)]:
      check matches("^\\W$", outside)
    for member in [9, 10, 11, 12, 13, 32, 0xA0, 0x1680, 0x2000, 0x2005, 0x200A, 0x2028,
                   0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF]:
      check not matches("^\\S$", $Rune(member))
    for outside in [0, 8, 14, 31, 33, 0x9F, 0xA1, 0x167F, 0x1681, 0x1FFF, 0x200B,
                    0x2027, 0x202A, 0x202E, 0x2030, 0x205E, 0x2060, 0x2FFF, 0x3001,
                    0xFEFE, 0xFF00, 0x10000, 0x10FFFF]:
      check matches("^\\S$", $Rune(outside))
    check matches("^[\\D]$", "a")
    check not matches("^[\\D]$", "5")

  test "Given an empty class, when matched, then [] matches nothing and [^] anything":
    check not matches("^[]$", "")
    check not matches("[]", "a")
    check matches("^[^]$", "x")
    check matches("^[^]$", "\n")
    # `]` does not belong to the class when it comes first: `[]a]` is the empty
    # class followed by "a]", which no text can satisfy.
    check not matches("[]a]", "a]")
    check not matches("[]a]", "]")
    check not matches("[]a]", "a")

  test "Given a class, when its members are written in the ways ECMA-262 allows, then each stands for what it names":
    check matches("^[^a]$", "^")
    check matches("^[^a]$", "b")
    check not matches("^[^a]$", "a")
    check matches("^[\\d]$", "5")
    check not matches("^[\\d]$", "d")
    check matches("^[\\s]$", " ")
    check not matches("^[\\s]$", "s")
    check matches("^[\\b]$", "\x08")
    check not matches("^[\\b]$", "b")
    check matches("^[a-]$", "a")
    check matches("^[a-]$", "-")
    check not matches("^[a-]$", "b")
    check not matches("^[a-]$", "]")
    check matches("^[a-c-e]$", "-")
    check matches("^[a-c-e]$", "e")
    check not matches("^[a-c-e]$", "d")
    check matches("^[\\x30-\\x39]$", "5")
    check not matches("^[\\x30-\\x39]$", "x")
    check not matches("^[\\x30-\\x39]$", "a")
    check matches("^[a-a]$", "a")
    check not matches("^[a-a]$", "b")

  test "Given a class that is not well formed, when compiled, then it is refused":
    for bad in ["[b-a]", "[a-", "[a", "[\\", "[a-\\", "["]:
      expect RegexError:
        discard compileRegex(bad)

  test "Given braces, when they are not a quantifier, then they stand for themselves":
    check matches("^a{,3}$", "a{,3}")
    check not matches("^a{,3}$", "aa")
    check matches("^a{x}$", "a{x}")

  test "Given a repetition, when its counts sit at the edges, then it matches exactly that many":
    check matches("^a{0}$", "")
    check not matches("^a{0}$", "a")
    check matches("^a{0,0}$", "")
    check not matches("^a{0,0}$", "a")
    check matches("^a{1,}$", "aaa")
    check not matches("^a{1,}$", "")
    check matches("^a{000000001}$", "a")
    check matches("^a{2,2}$", "aa")
    for text in ["", "a", "aaaa"]:
      check not matches("^a{2,3}$", text)
    for text in ["aa", "aaa"]:
      check matches("^a{2,3}$", text)

  test "Given a lazy quantifier after ?, when matched, then ?? is the lazy optional, not an error":
    check matches("^a??$", "")
    check matches("^a??$", "a")
    check not matches("^a??$", "aa")
    check matches("^xa?$", "xa")

  test "Given a repetition that runs backwards, when compiled, then it is refused":
    for bad in ["a{3,2}", "a{2,0}"]:
      expect RegexError:
        discard compileRegex(bad)

  test "Given a brace that is not closed or not a count, when matched, then ECMA-262 Annex B reads it as characters":
    for (pattern, text) in [("^a{$", "a{"), ("^a{2$", "a{2"), ("^a{2,$", "a{2,"),
                            ("^a{2x$", "a{2x"), ("^a{2x}$", "a{2x}"), ("^a{x}$", "a{x}"),
                            ("^a{,3}$", "a{,3}")]:
      check matches(pattern, text)
    # The count before an unclosed brace is no repetition: one "a" is not "aa{2".
    check not matches("^a{2$", "aa")
    check not matches("^a{2$", "a")
    # A closed repetition next to them is still a repetition.
    check matches("^a{2}b{$", "aab{")

  test "Given a repetition above the limit, when compiled, then the limit is reported whichever count is above":
    for big in ["a{1001}", "a{1001,}", "a{1,1001}", "a{1001,2000}"]:
      expect RegexLimitError:
        discard compileRegex(big)
    check matches("^a{1000}$", "a".repeat(1000))
    check matches("^a{1000,}$", "a".repeat(1000))
    check matches("^a{0,1000}$", "")

  test "Given alternatives, when matched, then the last one is as required as the others":
    check not matches("^(?:a|b)$", "")
    check not matches("^(?:a|b|c)$", "")
    check not matches("^(?:a|b)$", "c")
    for text in ["a", "b", "c"]:
      check matches("^(?:a|b|c)$", text)
    check matches("^(?:a|)$", "")

  test "Given parentheses that do not match, when compiled, then the pattern is refused":
    for bad in ["a)", "(a))", "(a", "(?", "(?:", "x(?"]:
      expect RegexError:
        discard compileRegex(bad)

  test "Given a group syntax that is not supported, when compiled, then the message names the group syntax":
    for bad in ["(?<n>x)", "(?x)", "(?i:x)"]:
      check "group syntax" in refusal(bad)

  test "Given groups one after another, when compiled, then only nesting counts against the nesting limit":
    check matches("^" & "(a)".repeat(70) & "$", "a".repeat(70))
    expect RegexLimitError:
      discard compileRegex("(".repeat(65) & "a" & ")".repeat(65))

  test "Given a backslash at the end of the pattern, when compiled, then the pattern is refused":
    for bad in ["a\\", "\\", "(\\", "[\\"]:
      expect RegexError:
        discard compileRegex(bad)

  test "Given a hex escape that ends the pattern, when compiled, then it is read, and one with fewer digits is refused":
    check matches("^\\x41$", "A")
    check matches("^\\u0041$", "A")
    check matches("\\x41", "xA")
    check matches("\\u0041", "A")
    for bad in ["\\x4", "\\x", "\\u004", "\\u00", "\\x4g", "\\u00zz"]:
      expect RegexError:
        discard compileRegex(bad)

  test "Given word boundaries, when matched at both ends of the text, then the text edge counts as a non-word":
    check matches("\\bab", "ab")
    check not matches("\\bab", "xab")
    check matches("ab\\b", "ab")
    check not matches("ab\\b", "abx")
    check not matches("\\Bab", "ab")
    check matches("\\Bab", "xab")
    check not matches("ab\\B", "ab")
    check matches("ab\\B", "abx")
    check matches("^a\\Bb$", "ab")
    check not matches("a\\B ", "a ")
    check matches("^\\B$", "")
    check matches("^\\B", " b")

  test "Given a lookahead, when matched, then it looks at the next characters only, not at the rest of the text":
    check matches("^a(?=b)", "ab")
    check not matches("^a(?=b)", "acb")
    check matches("^a(?!b)", "acb")
    check not matches("^a(?!b)", "ab")

  test "Given a pattern that is refused, when the cause is a quantifier with nothing to repeat, then the message points at it":
    check refusal("x|*").endsWith("at position 2")
    check refusal("*").endsWith("at position 0")
