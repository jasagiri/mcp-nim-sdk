## The JSON Schema validator and its regular expression engine against hostile
## input (a tool's arguments) and a hostile schema (an `outputSchema` from a
## server one does not trust): no stack exhaustion, no runaway matching, no
## unbounded recursion, no silent reading of a malformed number.

import std/[unittest, json, strutils]
import jsonschema/json_schema
import jsonschema/json_schema_regex

proc patternSchema(pattern: string): JsonNode =
  result = newJObject()
  result["pattern"] = %pattern

proc matches(pattern, text: string, limits = DefaultSchemaLimits): bool =
  ## Whether `text` conforms to a schema whose `pattern` is `pattern`.
  validate(patternSchema(pattern), %text, limits).len == 0

proc compiles(pattern: string, limits = DefaultSchemaLimits) =
  ## Raises InvalidSchemaError (SchemaLimitError for a limit) when `pattern` is refused.
  discard validate(patternSchema(pattern), %"", limits)


suite "regular expressions against catastrophic patterns":


  test "Given one budget for several matches, when they add up above it, then the later one is reported":
    let re = compileRegex("^[a-z]+$")
    var budget = 5000
    check re.isMatch('a'.repeat(100), budget)
    check budget < 5000
    expect RegexLimitError:
      for _ in 1 .. 100:
        discard re.isMatch('a'.repeat(100), budget)


proc nestedArrays(depth: int): JsonNode =
  result = newJInt(1)
  for _ in 1 .. depth:
    result = %[result]

suite "patterns with characters outside ASCII":

  test "Given a pattern with a literal character above U+00FF, when matched, then it stands for itself":
    # Each of these was a RangeDefect when compiled: the parser turned the
    # code point into a `char` to see whether it was a metacharacter.
    check compileRegex("^名前$").isMatch("名前")
    check not compileRegex("^名前$").isMatch("名")
    check compileRegex("あ+い").isMatch("ああい")
    check compileRegex("(あ|い)う").isMatch("いう")
    check compileRegex("x{2}あ").isMatch("xxあ")
    check not compileRegex("x{2}あ").isMatch("xあ")
    check compileRegex("^\xF0\x9F\x98\x80$").isMatch("\xF0\x9F\x98\x80")   # U+1F600

  test "Given an escaped character above U+00FF, when matched, then it stands for itself":
    check compileRegex("\\あ").isMatch("あ")
    check compileRegex("[\\あ]+").isMatch("ああ")

  test "Given a character above U+00FF wherever the syntax expects an ASCII one, when compiled, then the pattern compiles or is a RegexError":
    for before in ["", "\\", "(?", "(", "[", "[^", "[\\", "[a-", "a{", "a{2", "a{2,", "\\x", "\\x4", "\\u00", "a|", "a*", "\\b"]:
      for ch in ["あ", "\xC4\x80", "\xF0\x9F\x98\x80", "\xFC"]:
        for after in ["", ")", "]", "}", "a"]:
          try:
            discard compileRegex(before & ch & after)
          except RegexError:
            discard   # a pattern this engine does not read: the documented refusal


suite "numeric keywords that are written as floats":

  proc fails(schema, instance: string): bool =
    validate(parseJson(schema), parseJson(instance)).len > 0


suite "uniqueItems":

  proc duplicates(items: string): seq[string] =
    for violation in validate(parseJson("""{"uniqueItems": true}"""), parseJson(items)):
      result.add violation.message


proc limitsOf(maxDepth = DefaultSchemaLimits.maxDepth, maxChecks = DefaultSchemaLimits.maxChecks): SchemaLimits =
  SchemaLimits(maxDepth: maxDepth, maxChecks: maxChecks,
               maxRegexSteps: DefaultSchemaLimits.maxRegexSteps, regex: DefaultSchemaLimits.regex)

proc conformsWithin(schema, instance: string, limits: SchemaLimits): bool =
  validate(parseJson(schema), parseJson(instance), limits).len == 0


suite "regular expression limits (mutation review, g2h-js-b)":

  let small = RegexLimits(maxPatternLength: 100, maxRepeat: 10, maxProgramSize: 4, maxNesting: 4)

  test "Given a compiled pattern, when asked its size, then it is the instructions it needs, the final match included":
    check compileRegex("abc").size == 4
    check compileRegex("").size == 1

  test "Given a program of exactly the size limit, when compiled, then it is accepted and one instruction more is refused":
    check compileRegex("abc", small).size == 4
    expect RegexLimitError:
      discard compileRegex("abcd", small)

  test "Given a pattern whose parts emit nothing, when it does as much work as the limit allows, then it is accepted and one step more is refused":
    # Four times the program size limit is the work allowed; `(?:)` costs one
    # step and emits nothing, so only the work limit can stop a run of them.
    let tiny = RegexLimits(maxPatternLength: 100, maxRepeat: 10, maxProgramSize: 1, maxNesting: 4)
    check compileRegex("(?:)(?:)(?:)", tiny).size == 1
    expect RegexLimitError:
      discard compileRegex("(?:)(?:)(?:)(?:)", tiny)

  test "Given a step budget that is exactly what a match needs, when matched, then it is answered and the budget is spent":
    # One step for each instruction visited: `a` over "a" visits the char, the
    # char again once it consumes "a", and the final match.
    var budget = 3
    check compileRegex("a").isMatch("a", budget)
    check budget == 0
    expect RegexLimitError:
      discard compileRegex("a").isMatch("a", 2)

