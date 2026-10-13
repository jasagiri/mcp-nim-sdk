## The JSON Schema validator and its regular expression engine against hostile
## input (a tool's arguments) and a hostile schema (an `outputSchema` from a
## server one does not trust): no stack exhaustion, no runaway matching, no
## unbounded recursion, no silent reading of a malformed number.

import std/[unittest, json, strutils, sequtils]
import jsonschema/json_schema

proc patternSchema(pattern: string): JsonNode =
  result = newJObject()
  result["pattern"] = %pattern

proc matches(pattern, text: string, limits = DefaultSchemaLimits): bool =
  ## Whether `text` conforms to a schema whose `pattern` is `pattern`.
  validate(patternSchema(pattern), %text, limits).len == 0

proc compiles(pattern: string, limits = DefaultSchemaLimits) =
  ## Raises InvalidSchemaError (SchemaLimitError for a limit) when `pattern` is refused.
  discard validate(patternSchema(pattern), %"", limits)

suite "regular expressions against long text":

  test "Given a plain pattern, when 4 MiB of text is matched, then the process survives and answers":
    let text = 'a'.repeat(4 * 1024 * 1024)
    check matches("^[a-z]+$", text)
    let shorter = text[0 ..< 512 * 1024]
    check not matches("^[a-z]+$", shorter & "1")
    check matches("^(?:ab|a)*$", shorter)
    check matches("^(a|b)+$", shorter)

  test "Given a lookahead, when long text is matched, then it is answered":
    let text = 'a'.repeat(1024 * 1024)
    check matches("^(?=[a-z]+$)(?!.*b).*$", text)
    check not matches("^(?=[a-z]+$)(?!.*a).*$", text)

suite "regular expressions against catastrophic patterns":

  test "Given patterns that backtrack exponentially, when matched, then each answers at once":
    let text = 'a'.repeat(100_000) & "b"
    check matches("(a|a)*$", text)
    check not matches("^(a+)+$", text)
    check not matches("^(a|aa)+$", text)
    check not matches("^(a*)*$", text)
    check not matches("^(.*a){20}$", text[0 ..< 100] & "b")

  test "Given a match that needs more steps than the budget, when matched, then the limit is reported, not a verdict":
    var limits = DefaultSchemaLimits
    limits.maxRegexSteps = 100
    expect SchemaLimitError:
      discard matches("^[a-z]+$", 'a'.repeat(1000), limits)


suite "regular expressions against huge patterns":

  test "Given a repetition count above the limit, when compiled, then the limit is reported":
    expect SchemaLimitError: compiles("a{1000000}")
    expect SchemaLimitError: compiles("a{1,1000000}")
    expect SchemaLimitError: compiles("a{99999999999999999999}")
    check matches("^a{1000}$", 'a'.repeat(1000))

  test "Given repetitions nested inside each other, when compiled, then the expansion is stopped":
    expect SchemaLimitError: compiles("((((a{1000}){1000}){1000}){1000})")
    expect SchemaLimitError: compiles("(((?:){1000}){1000}){1000}")

  test "Given a pattern longer than the limit, when compiled, then the limit is reported":
    expect SchemaLimitError: compiles("a".repeat(4097))
    check matches("a".repeat(4096), "a".repeat(4096))

  test "Given groups nested too deep, when compiled, then the limit is reported":
    expect SchemaLimitError: compiles("(".repeat(65) & ")".repeat(65))
    check matches("(".repeat(64) & "a" & ")".repeat(64), "a")

  test "Given a limit raised by the caller, when compiled, then the larger pattern is accepted":
    var limits = DefaultSchemaLimits
    limits.regex.maxRepeat = 5000
    check matches("^a{5000}$", 'a'.repeat(5000), limits)

proc nestedArrays(depth: int): JsonNode =
  result = newJInt(1)
  for _ in 1 .. depth:
    result = %[result]

suite "patterns with characters outside ASCII":


  test "Given a schema whose pattern has a character above U+00FF, when validated, then the pattern is applied":
    let schema = parseJson("""{"type": "string", "pattern": "^[ぁ-ん]+さん$"}""")
    check validate(schema, %"たなかさん").len == 0
    check validate(schema, %"tanaka-san").len == 1

suite "schemas that refer to themselves":

  test "Given a $ref to the root, when an instance is validated, then the schema is reported invalid":
    expect InvalidSchemaError:
      discard validate(parseJson("""{"$ref": "#"}"""), %1)

  test "Given $refs that point at each other, when an instance is validated, then the cycle is reported":
    let schema = parseJson("""{"$defs": {"a": {"$ref": "#/$defs/b"}, "b": {"$ref": "#/$defs/a"}},
                               "$ref": "#/$defs/a"}""")
    expect InvalidSchemaError:
      discard validate(schema, %1)

  test "Given a $ref cycle through allOf, when an instance is validated, then the cycle is reported":
    expect InvalidSchemaError:
      discard validate(parseJson("""{"allOf": [{"$ref": "#"}]}"""), %1)

  test "Given a recursive schema that reads deeper into the instance, when it is validated, then it conforms":
    let schema = parseJson("""{"type": "object", "properties": {"child": {"$ref": "#"}}}""")
    var tree = newJObject()
    for _ in 1 .. 50:
      tree = %*{"child": tree}
    check validate(schema, tree).len == 0
    check validate(schema, %*{"child": {"child": 5}}).len == 1

  test "Given contains that refers to its own schema, when nested arrays are validated, then there is no false cycle":
    let schema = parseJson("""{"$defs": {"x": {"type": ["array", "integer"],
                                               "contains": {"$ref": "#/$defs/x"}}},
                               "$ref": "#/$defs/x"}""")
    check validate(schema, nestedArrays(5)).len == 0

suite "limits on depth and total work":

  test "Given an instance nested deeper than the limit, when a recursive schema reads it, then the limit is reported":
    let schema = parseJson("""{"type": ["array", "integer"], "items": {"$ref": "#"}}""")
    expect SchemaLimitError:
      discard validate(schema, nestedArrays(2000))
    check validate(schema, nestedArrays(50)).len == 0

  test "Given a schema nested deeper than the limit, when validated, then the limit is reported":
    var schema = parseJson("""{"type": "integer"}""")
    for _ in 1 .. 2000:
      schema = %*{"allOf": [schema]}
    expect SchemaLimitError:
      discard validate(schema, %1)

  test "Given a depth limit raised by the caller, when a deeper instance is validated, then it is accepted":
    let schema = parseJson("""{"type": ["array", "integer"], "items": {"$ref": "#"}}""")
    var limits = DefaultSchemaLimits
    limits.maxDepth = 400
    expect SchemaLimitError:
      discard validate(schema, nestedArrays(150))
    check validate(schema, nestedArrays(150), limits).len == 0

  test "Given $refs that double at every level, when validated, then the work limit stops it":
    var defs = newJObject()
    for level in 0 ..< 60:
      defs["d" & $level] = %*{"allOf": [{"$ref": "#/$defs/d" & $(level + 1)},
                                        {"$ref": "#/$defs/d" & $(level + 1)}]}
    defs["d60"] = %*{"type": "integer"}
    let schema = %*{"$defs": defs, "$ref": "#/$defs/d0"}
    var limits = DefaultSchemaLimits
    limits.maxChecks = 100_000
    expect SchemaLimitError:
      discard validate(schema, %1, limits)
    # 2^60 applications would never finish under the default either.
    check DefaultSchemaLimits.maxChecks < 1 shl 30

  test "Given a pattern the engine refuses by size, when validated, then the schema is reported invalid with the limit":
    expect SchemaLimitError:
      discard validate(parseJson("""{"pattern": "a{1000000}"}"""), %"a")

  test "Given many matches that add up above the regex budget, when validated, then the limit is reported":
    var limits = DefaultSchemaLimits
    limits.maxRegexSteps = 10_000
    let schema = parseJson("""{"items": {"pattern": "^[a-z]+$"}}""")
    let strings = %(newSeq[string](200).mapIt("abcdefghijklmnopqrstuvwxyz"))
    expect SchemaLimitError:
      discard validate(schema, strings, limits)
    check validate(schema, strings).len == 0

  test "Given a 4 MiB string and a pattern, when validated, then the answer is given":
    let text = %('a'.repeat(4 * 1024 * 1024))
    check validate(parseJson("""{"pattern": "^[a-z]+$"}"""), text).len == 0
    let shorter = %('a'.repeat(512 * 1024))
    check validate(parseJson("""{"pattern": "^[0-9]+$"}"""), shorter).len == 1
    check validate(parseJson("""{"pattern": "(a|a)*$"}"""), shorter).len == 0

suite "numeric keywords that are written as floats":

  proc fails(schema, instance: string): bool =
    validate(parseJson(schema), parseJson(instance)).len > 0

  test "Given a length or size limit written as 5.0, when an instance breaks it, then it is reported like 5":
    check fails("""{"minLength": 5.0}""", "\"abc\"")
    check fails("""{"maxLength": 2.0}""", "\"abc\"")
    check fails("""{"minItems": 2.0}""", "[1]")
    check fails("""{"maxItems": 1.0}""", "[1, 2]")
    check fails("""{"minProperties": 2.0}""", """{"a": 1}""")
    check fails("""{"maxProperties": 1.0}""", """{"a": 1, "b": 2}""")
    check fails("""{"contains": true, "minContains": 2.0}""", "[1]")
    check fails("""{"contains": true, "maxContains": 1.0}""", "[1, 2]")

  test "Given a limit written as 5.0, when an instance keeps it, then it conforms":
    check not fails("""{"minLength": 3.0, "maxLength": 3.0}""", "\"abc\"")
    check not fails("""{"minItems": 1.0, "maxItems": 2.0}""", "[1, 2]")
    check not fails("""{"minLength": 0.0}""", "\"\"")
    check not fails("""{"maxLength": 1e300}""", "\"abc\"")
    check fails("""{"minLength": 1e300}""", "\"abc\"")

  test "Given a limit that is not a non-negative integer, when validated, then the schema is invalid":
    for (keyword, instance) in [("minLength", "\"abc\""), ("maxLength", "\"abc\""),
                                ("minItems", "[1]"), ("maxItems", "[1]"),
                                ("minProperties", """{"a": 1}"""),
                                ("maxProperties", """{"a": 1}"""),
                                ("minContains", "[1]"), ("maxContains", "[1]")]:
      for bad in ["2.5", "-1", "-1.0", "\"2\"", "null", "true"]:
        let schema = parseJson("{\"contains\": true, \"" & keyword & "\": " & bad & "}")
        expect InvalidSchemaError:
          discard validate(schema, parseJson(instance))

suite "uniqueItems":

  proc duplicates(items: string): seq[string] =
    for violation in validate(parseJson("""{"uniqueItems": true}"""), parseJson(items)):
      result.add violation.message

  test "Given 100000 distinct items, when uniqueItems is checked, then it finishes at once":
    var items = newJArray()
    for i in 0 ..< 100_000:
      items.add %*{"id": i, "tags": ["a", $i]}
    check validate(parseJson("""{"uniqueItems": true}"""), items).len == 0
    items.add %*{"tags": ["a", "5"], "id": 5}
    let found = validate(parseJson("""{"uniqueItems": true}"""), items)
    check found.len == 1
    check found[0].message == "items 5 and 100000 are equal"

  test "Given items that are equal as JSON values, when uniqueItems is checked, then they are reported":
    check duplicates("[1, 1.0]").len == 1
    check duplicates("[0, -0.0]").len == 1
    check duplicates("""[{"a": 1, "b": 2}, {"b": 2, "a": 1}]""").len == 1
    check duplicates("""[{"a": 1}, {"a": 1.0}]""").len == 1
    check duplicates("""[{"a": [1, {"b": 2}]}, {"a": [1.0, {"b": 2.0}]}]""").len == 1
    check duplicates("""["x", "x"]""").len == 1
    check duplicates("[null, null]").len == 1
    check duplicates("[1.5, 1.5]").len == 1
    check duplicates("[1e2, 100]").len == 1

  test "Given items that only look alike, when uniqueItems is checked, then they are distinct":
    check duplicates("[[1, 2], [2, 1]]").len == 0
    check duplicates("""["1", 1]""").len == 0
    check duplicates("[true, 1]").len == 0
    check duplicates("[null, false]").len == 0
    check duplicates("[0, false]").len == 0
    check duplicates("""[{"a": 1}, {"a": 1, "b": null}]""").len == 0
    check duplicates("""[["a", "b"], ["ab"]]""").len == 0
    check duplicates("""[["a,b"], ["a", "b"]]""").len == 0
    check duplicates("[9007199254740993, 9007199254740992]").len == 0
    check duplicates("[1.5, 1.50001]").len == 0

  test "Given three equal items, when uniqueItems is checked, then each later copy names the first":
    check duplicates("[7, 7, 7]") == @["items 0 and 1 are equal", "items 0 and 2 are equal"]

  test "Given enum and const with 1 and 1.0, when large integers are compared, then they are told apart":
    check validate(parseJson("""{"const": 9007199254740993}"""), parseJson("9007199254740992")).len == 1
    check validate(parseJson("""{"const": 1}"""), parseJson("1.0")).len == 0

suite "malformed keywords that were skipped or crashed":

  test "Given a $ref with an array index that overflows, when validated, then the schema is invalid":
    expect InvalidSchemaError:
      discard validate(parseJson("""{"$defs": {"a": [true]}, "$ref": "#/$defs/a/99999999999999999999"}"""), %1)

  test "Given a $ref with an index that is out of range, when validated, then the schema is invalid":
    expect InvalidSchemaError:
      discard validate(parseJson("""{"$defs": {"a": [true]}, "$ref": "#/$defs/a/1"}"""), %1)

  test "Given dependentRequired in a form that is not a list of names, when an object is validated, then the schema is invalid":
    for bad in ["\"b\"", "5", "[1]", "[\"b\", null]", "{}"]:
      expect InvalidSchemaError:
        discard validate(parseJson("{\"dependentRequired\": {\"a\": " & bad & "}}"),
                         parseJson("""{"a": 1, "b": 2}"""))

  test "Given draft-07 dependencies in a form that is neither a list of names nor a schema, when validated, then the schema is invalid":
    for bad in ["\"b\"", "5", "[1]", "null"]:
      expect InvalidSchemaError:
        discard validate(parseJson("{\"$schema\": \"http://json-schema.org/draft-07/schema#\", \"dependencies\": {\"a\": " & bad & "}}"),
                         parseJson("""{"a": 1, "b": 2}"""))

  test "Given multipleOf whose quotient is beyond a double, when validated, then it is reported, not passed":
    expect SchemaLimitError:
      discard validate(parseJson("""{"multipleOf": 1e-308}"""), parseJson("1e308"))
    check validate(parseJson("""{"multipleOf": 0.5}"""), parseJson("2.5")).len == 0
    check validate(parseJson("""{"multipleOf": 0.5}"""), parseJson("2.6")).len == 1

proc limitsOf(maxDepth = DefaultSchemaLimits.maxDepth, maxChecks = DefaultSchemaLimits.maxChecks): SchemaLimits =
  SchemaLimits(maxDepth: maxDepth, maxChecks: maxChecks,
               maxRegexSteps: DefaultSchemaLimits.maxRegexSteps, regex: DefaultSchemaLimits.regex)

proc conformsWithin(schema, instance: string, limits: SchemaLimits): bool =
  validate(parseJson(schema), parseJson(instance), limits).len == 0

suite "JSON Schema limits (mutation review, g2h-js-a)":

  test "Given maxDepth, when the schema nests exactly that deep, then it is validated and one level more is reported":
    let schema = """{"properties": {"a": {"type": "integer"}}}"""
    check conformsWithin("""{"type": "integer"}""", "5", limitsOf(maxDepth = 1))
    check conformsWithin(schema, """{"a": 1}""", limitsOf(maxDepth = 2))
    expect SchemaLimitError:
      discard conformsWithin(schema, """{"a": 1}""", limitsOf(maxDepth = 1))

  test "Given maxDepth, when many sibling schemas are applied one after another, then only the nesting counts":
    check conformsWithin("""{"allOf": [{"type": "integer"}, {"type": "integer"}, {"type": "integer"}]}""",
                         "5", limitsOf(maxDepth = 2))
    check conformsWithin("""{"items": {"type": "integer"}}""", "[1, 2, 3, 4]", limitsOf(maxDepth = 2))

  test "Given maxChecks, when the validation needs exactly that many schema applications, then it is validated and one more is reported":
    let schema = """{"properties": {"a": {}}}"""
    check conformsWithin("""{"type": "integer"}""", "5", limitsOf(maxChecks = 1))
    check conformsWithin(schema, """{"a": 1}""", limitsOf(maxChecks = 2))
    expect SchemaLimitError:
      discard conformsWithin(schema, """{"a": 1}""", limitsOf(maxChecks = 1))
    expect SchemaLimitError:
      discard conformsWithin("true", "5", limitsOf(maxChecks = 0))

  test "Given uniqueItems, when an item nests as deep as maxDepth, then comparing it is reported and one level less is compared":
    let unique = """{"uniqueItems": true}"""
    check conformsWithin(unique, "[[1], [2]]", limitsOf(maxDepth = 2))
    expect SchemaLimitError:
      discard conformsWithin(unique, "[[[1]]]", limitsOf(maxDepth = 2))
    check conformsWithin(unique, """[{"a": 1}, {"a": 2}]""", limitsOf(maxDepth = 2))
    expect SchemaLimitError:
      discard conformsWithin(unique, """[{"a": {"b": 1}}]""", limitsOf(maxDepth = 2))

  test "Given uniqueItems, when items nest far deeper than maxDepth, then comparing them is reported, however the nesting is built":
    let unique = """{"uniqueItems": true}"""
    expect SchemaLimitError:
      discard conformsWithin(unique, "[" & "[".repeat(40) & "1" & "]".repeat(40) & "]", limitsOf(maxDepth = 8))
    expect SchemaLimitError:
      discard conformsWithin(unique, "[" & """{"a":""".repeat(40) & "1" & "}".repeat(40) & "]", limitsOf(maxDepth = 8))


suite "regular expression limits (mutation review, g2h-js-b)":

  let small = RegexLimits(maxPatternLength: 100, maxRepeat: 10, maxProgramSize: 4, maxNesting: 4)


suite "the limits on a pattern, seen through the validator":

  test "Given a pattern whose program is exactly the size limit, when a schema with it is validated, then it is applied, and one instruction more is a SchemaLimitError":
    # `abc` is three characters and the final match: four instructions.
    var limits = DefaultSchemaLimits
    limits.regex.maxProgramSize = 4
    check matches("abc", "abc", limits)
    check not matches("abc", "abd", limits)
    expect SchemaLimitError:
      compiles("abcd", limits)
    limits.regex.maxProgramSize = 3
    expect SchemaLimitError:
      compiles("abc", limits)

  test "Given a pattern whose parts emit nothing, when it does as much work as the limit allows, then it is applied, and one step more is a SchemaLimitError":
    # Four times the program size limit is the work allowed; `(?:)` costs one
    # step and emits nothing, so only the work limit can stop a run of them.
    var limits = DefaultSchemaLimits
    limits.regex.maxProgramSize = 1
    check matches("(?:)(?:)(?:)", "anything", limits)
    expect SchemaLimitError:
      compiles("(?:)(?:)(?:)(?:)", limits)

  test "Given a step budget that is exactly what a pattern and its match need, when validated, then it is answered, and with one step less it is a SchemaLimitError":
    # The budget pays for the program of `^a$` (start, the character, end and
    # the final match: four instructions) and for one visit of each of them
    # over "a", the character twice: once to reach it and once to consume.
    var limits = DefaultSchemaLimits
    limits.maxRegexSteps = 9
    check matches("^a$", "a", limits)
    limits.maxRegexSteps = 8
    expect SchemaLimitError:
      discard matches("^a$", "a", limits)
