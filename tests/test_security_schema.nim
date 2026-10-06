## The JSON Schema validator and its regular expression engine against hostile
## input (a tool's arguments) and a hostile schema (an `outputSchema` from a
## server one does not trust): no stack exhaustion, no runaway matching, no
## unbounded recursion, no silent reading of a malformed number.

import std/[unittest, strutils]
import jsonschema/json_schema_regex

suite "regular expressions against long text":

  test "Given a plain pattern, when 4 MiB of text is matched, then the process survives and answers":
    let text = 'a'.repeat(4 * 1024 * 1024)
    check compileRegex("^[a-z]+$").isMatch(text)
    check not compileRegex("^[a-z]+$").isMatch(text & "1")
    check compileRegex("^(?:ab|a)*$").isMatch(text)
    check compileRegex("^(a|b)+$").isMatch(text)

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
