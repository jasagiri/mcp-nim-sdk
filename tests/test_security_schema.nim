## The JSON Schema validator and its regular expression engine against hostile
## input (a tool's arguments) and a hostile schema (an `outputSchema` from a
## server one does not trust): no stack exhaustion, no runaway matching, no
## unbounded recursion, no silent reading of a malformed number.

import std/[unittest, json, strutils, sequtils]
import jsonschema/json_schema
import jsonschema/json_schema_regex

suite "regular expressions against long text":

  test "Given a plain pattern, when 4 MiB of text is matched, then the process survives and answers":
    let text = 'a'.repeat(4 * 1024 * 1024)
    check compileRegex("^[a-z]+$").isMatch(text)
    let shorter = text[0 ..< 512 * 1024]
    check not compileRegex("^[a-z]+$").isMatch(shorter & "1")
    check compileRegex("^(?:ab|a)*$").isMatch(shorter)
    check compileRegex("^(a|b)+$").isMatch(shorter)

  test "Given a lookahead, when long text is matched, then it is answered":
    let text = 'a'.repeat(1024 * 1024)
    check compileRegex("^(?=[a-z]+$)(?!.*b).*$").isMatch(text)
    check not compileRegex("^(?=[a-z]+$)(?!.*a).*$").isMatch(text)

suite "regular expressions against catastrophic patterns":

  test "Given patterns that backtrack exponentially, when matched, then each answers at once":
    let text = 'a'.repeat(100_000) & "b"
    check compileRegex("(a|a)*$").isMatch(text)
    check not compileRegex("^(a+)+$").isMatch(text)
    check not compileRegex("^(a|aa)+$").isMatch(text)
    check not compileRegex("^(a*)*$").isMatch(text)
    check not compileRegex("^(.*a){20}$").isMatch(text[0 ..< 100] & "b")

  test "Given a match that needs more steps than the budget, when matched, then the limit is reported, not a verdict":
    let re = compileRegex("^[a-z]+$")
    expect RegexLimitError:
      discard re.isMatch('a'.repeat(1000), maxSteps = 100)

  test "Given one budget for several matches, when they add up above it, then the later one is reported":
    let re = compileRegex("^[a-z]+$")
    var budget = 5000
    check re.isMatch('a'.repeat(100), budget)
    check budget < 5000
    expect RegexLimitError:
      for _ in 1 .. 100:
        discard re.isMatch('a'.repeat(100), budget)

suite "regular expressions against huge patterns":

  test "Given a repetition count above the limit, when compiled, then the limit is reported":
    expect RegexLimitError: discard compileRegex("a{1000000}")
    expect RegexLimitError: discard compileRegex("a{1,1000000}")
    expect RegexLimitError: discard compileRegex("a{99999999999999999999}")
    check compileRegex("^a{1000}$").isMatch('a'.repeat(1000))

  test "Given repetitions nested inside each other, when compiled, then the expansion is stopped":
    expect RegexLimitError: discard compileRegex("((((a{1000}){1000}){1000}){1000})")
    expect RegexLimitError: discard compileRegex("(((?:){1000}){1000}){1000}")

  test "Given a pattern longer than the limit, when compiled, then the limit is reported":
    expect RegexLimitError: discard compileRegex("a".repeat(4097))
    check compileRegex("a".repeat(4096)).isMatch("a".repeat(4096))

  test "Given groups nested too deep, when compiled, then the limit is reported":
    expect RegexLimitError: discard compileRegex("(".repeat(65) & ")".repeat(65))
    check compileRegex("(".repeat(64) & "a" & ")".repeat(64)).isMatch("a")

  test "Given a limit raised by the caller, when compiled, then the larger pattern is accepted":
    var limits = DefaultRegexLimits
    limits.maxRepeat = 5000
    check compileRegex("^a{5000}$", limits).isMatch('a'.repeat(5000))

proc nestedArrays(depth: int): JsonNode =
  result = newJInt(1)
  for _ in 1 .. depth:
    result = %[result]

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
