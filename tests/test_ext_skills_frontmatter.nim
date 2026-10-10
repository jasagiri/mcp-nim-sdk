## What the skills extension's frontmatter reader accepts, what it refuses and
## why. The file is input from a server, so every refusal is a FrontmatterError
## (never an index error) and every accepted spelling reads as YAML would.

import std/[json, strutils, unittest]
import ext/skills/frontmatter

proc fieldsOf(lines: varargs[string]): JsonNode =
  parseFrontmatter("---\n" & lines.join("\n") & "\n---\n").fields

proc errorOf(text: string): string =
  ## The message of the FrontmatterError, or "" when none is raised.
  try:
    discard parseFrontmatter(text)
    ""
  except FrontmatterError as e:
    e.msg

proc valueOf(raw: string): JsonNode =
  fieldsOf("v: " & raw)["v"]

suite "frontmatter: double-quoted scalars":

  test "Given the escapes of a double-quoted scalar, when read, then each becomes its character":
    check valueOf(r""""x\ny\tz\rw\0v\"u\\t\/s"""") == %"x\ny\tz\rw\0v\"u\\t/s"

  test "Given hexadecimal escapes, when read, then each takes exactly its digits":
    check valueOf(r""""\x41BC"""") == %"ABC"
    check valueOf(r""""\u00e9BC"""") == %"\u00e9BC"
    check valueOf(r""""\U0001F600BC"""") == %"\u{1F600}BC"
    check valueOf(r""""\x00"""") == %"\0"

  test "Given the last code point, when escaped, then it is accepted and the one after it is refused":
    check valueOf(r""""\U0010FFFF"""") == %"\u{10FFFF}"
    check errorOf("---\nv: \"\\U00110000\"\n---\n").len > 0

  test "Given escapes that are cut short, malformed or not characters, when read, then FrontmatterError is raised":
    for bad in [r""""\x"""", r""""\x4"""", r""""\u12"""", r""""\u123"""", r""""\U0001F60"""",
                r""""\xZZ"""", r""""\x-1"""", r""""\ud800"""", r""""\udfff"""", r""""\q"""", r""""abc\""""]:
      checkpoint bad
      expect FrontmatterError:
        discard fieldsOf("v: " & bad)

suite "frontmatter: single-quoted scalars":

  test "Given doubled quotes, when read, then each is one quote":
    check valueOf("'it''s'") == %"it's"
    check valueOf("'a'''") == %"a'"
    check valueOf("'\\n stays'") == %"\\n stays"

  test "Given empty quoted scalars, when read, then they are empty strings":
    check valueOf("\"\"") == %""
    check valueOf("''") == %""

  test "Given quoted scalars that do not end on their line, when read, then FrontmatterError is raised":
    for bad in ["\"", "'", "\"abc", "'abc"]:
      checkpoint bad
      expect FrontmatterError:
        discard fieldsOf("v: " & bad)

suite "frontmatter: plain scalars":

  test "Given every spelling of null, when read, then it is JSON null":
    for spelling in ["~", "null", "Null", "NULL"]:
      checkpoint spelling
      check valueOf(spelling).kind == JNull
    check valueOf("[~, null, Null, NULL]") == %*[nil, nil, nil, nil]

  test "Given every spelling of a boolean, when read, then it is a JSON boolean":
    for spelling in ["true", "True", "TRUE"]:
      check valueOf(spelling) == %true
    for spelling in ["false", "False", "FALSE"]:
      check valueOf(spelling) == %false

  test "Given numbers and words that look like numbers, when read, then only numbers become numbers":
    check valueOf("-7") == %(-7)
    check valueOf(".5") == %0.5
    check valueOf("-2.5e3") == %(-2500.0)
    check valueOf("1e3") == %1000.0
    for word in ["inf", "nan", "Infinity", "1.2.3", "v1.2", "e5", "example.com", "12abc"]:
      checkpoint word
      check valueOf(word) == %word

  test "Given a hash, when it does not follow a space, then it belongs to the scalar":
    check valueOf("a#b") == %"a#b"
    check valueOf("5#") == %"5#"

  test "Given a hash after a space, when read, then the rest of the line is a comment":
    check valueOf("value #comment") == %"value"
    check valueOf("value # comment") == %"value"
    check valueOf("value   #") == %"value"

  test "Given a quote in the middle of a plain scalar, when a comment follows, then the quote opens nothing":
    check valueOf("say\"hi # c") == %"say\"hi"

  test "Given a hash inside quotes, when a comment follows the quotes, then only the comment is dropped":
    check valueOf("\"a # b\" # c") == %"a # b"
    check valueOf("'x # y'  # z") == %"x # y"
    check valueOf("[\"a # b\", c] # d") == %*["a # b", "c"]

suite "frontmatter: flow sequences":

  test "Given empty, single and several items, when read, then the array has as many":
    check valueOf("[]") == %*[]
    check valueOf("[ ]") == %*[]
    check valueOf("[a]") == %*["a"]
    check valueOf("[\"a, b\", 'c']") == %*["a, b", "c"]

  test "Given a sequence that does not close on its line or nests, when read, then FrontmatterError is raised":
    for bad in ["[a, b", "[a,", "[\"x]", "[a, [b]]", "[a, {b}]"]:
      checkpoint bad
      expect FrontmatterError:
        discard fieldsOf("v: " & bad)

suite "frontmatter: keys":

  test "Given quoted keys, when read, then they are unquoted the way their quotes say":
    check fieldsOf("\"k\\u00e9y\": 1", "'k\\n': 2", "\"a b\": 3", "\"k\\n\": 4") ==
      %*{"k\u00e9y": 1, "k\\n": 2, "a b": 3, "k\n": 4}

  test "Given a key with a space or a colon not followed by a space, when read, then the colon ends the key only before a space":
    check fieldsOf("my key: v", "a:b: c", "url: http://x.y/z") ==
      %*{"my key": "v", "a:b": "c", "url": "http://x.y/z"}

  test "Given lines that are not a key and a value, when read, then FrontmatterError is raised":
    for bad in ["bare", "\"abc: x", "'abc: x", "\"a\"", "\"a\" b: c", "'a'x: y", ": v", "\"\": v"]:
      checkpoint bad
      expect FrontmatterError:
        discard fieldsOf("name: x", bad)

suite "frontmatter: block scalars":

  test "Given a literal block with a blank line inside, when read, then the blank line stays":
    check fieldsOf("a: |", "  one", "", "  two", "next: 1") == %*{"a": "one\n\ntwo\n", "next": 1}

  test "Given a block scalar that is the last field, when read, then it ends with the frontmatter":
    check fieldsOf("a: |", "  only")["a"] == %"only\n"

  test "Given a block scalar with no lines, when read, then it is empty whether it is clipped or stripped":
    check fieldsOf("a: |", "b: 1") == %*{"a": "", "b": 1}
    check fieldsOf("a: |-", "b: 1")["a"] == %""

  test "Given blank lines after a block scalar, when chomped, then clip keeps one newline, strip none and keep all":
    check fieldsOf("a: |", "  one", "", "", "b: 1")["a"] == %"one\n"
    check fieldsOf("a: |-", "  one", "", "", "b: 1")["a"] == %"one"
    check fieldsOf("a: |+", "  one", "", "", "b: 1")["a"] == %"one\n\n\n"

  test "Given a block scalar header with more than a chomping indicator, when read, then FrontmatterError is raised":
    expect FrontmatterError:
      discard fieldsOf("a: |2", "  one")

suite "frontmatter: layout":

  test "Given blank and comment lines between fields, when read, then they are ignored":
    check fieldsOf("a: \"x\"", "", "b: [1]", "# c", "c:", "", "d: 2", "e: 'y'", "", "f: 3") ==
      %*{"a": "x", "b": [1], "c": nil, "d": 2, "e": "y", "f": 3}

  test "Given a blank line between a key and its nested mapping, when read, then the mapping is the value":
    check fieldsOf("a:", "", "  b: 1", "c: 2") == %*{"a": {"b": 1}, "c": 2}

  test "Given a key with nothing after it at the end, when read, then it is null":
    check fieldsOf("name: x", "last:")["last"].kind == JNull
    check fieldsOf("name: x", "last:", "# c", "")["last"].kind == JNull

  test "Given a comment before an indented mapping, when read, then the mapping is read at its own indent":
    check fieldsOf("# c", "  name: x", "  other: y") == %*{"name": "x", "other": "y"}

  test "Given a sequence indented under its key, when it has blank lines between items, then they are all items":
    check fieldsOf("words:", "  - x", "", "  - y", "next: 1") == %*{"words": ["x", "y"], "next": 1}

  test "Given a sequence written at the indent of its key, when it is the last field, then it is that key's value":
    check fieldsOf("name: x", "words:", "- x", "- y") == %*{"name": "x", "words": ["x", "y"]}

  test "Given a sequence written at the indent of its key, when other fields follow it, then they are read":
    check fieldsOf("words:", "- x", "- y", "next: 1", "more:", "- z") ==
      %*{"words": ["x", "y"], "next": 1, "more": ["z"]}

  test "Given a sequence item that is not a scalar, when read, then FrontmatterError is raised":
    for bad in ["  - : x", "  - a: b", "  -"]:
      checkpoint bad
      expect FrontmatterError:
        discard fieldsOf("words:", bad)

  test "Given a line in a sequence that is not an item or is indented further, when read, then FrontmatterError is raised":
    for bad in [@["  - x", "  ab"], @["  - x", "    - y"]]:
      checkpoint $bad
      expect FrontmatterError:
        discard fieldsOf("words:" & bad)

  test "Given content left of the first field's indent, when read, then FrontmatterError is raised":
    expect FrontmatterError:
      discard fieldsOf("  a: 1", "b: 2")

suite "frontmatter: the fences":

  test "Given text before the opening fence, when read, then it is refused":
    for bad in ["name: x\n---\nbody", "\n---\nname: x\n---\n", " ---\nname: x\n---\n", ""]:
      checkpoint bad
      expect FrontmatterError:
        discard parseFrontmatter(bad)

  test "Given a fence with trailing spaces, when read, then it is a fence":
    let read = parseFrontmatter("---  \nname: x\n--- \t\nbody")
    check read.fields == %*{"name": "x"}
    check read.body == "body"

  test "Given an indented closing fence, when read, then it is not a fence":
    expect FrontmatterError:
      discard parseFrontmatter("---\nname: x\n ---\nbody\n")

  test "Given only comments and blank lines, when read, then there are no fields":
    check parseFrontmatter("---\n# only a comment\n---\n").fields.len == 0
    check parseFrontmatter("---\n\n  \n# c\n---\n").fields.len == 0

  test "Given whitespace after the content, when it is a tab, then it is not indentation":
    check fieldsOf("a:\t\t\t") == %*{"a": nil}
    check fieldsOf("a: 1\t\t\t\t\t") == %*{"a": 1}

  test "Given a tab in the indentation, when read, then FrontmatterError is raised":
    expect FrontmatterError:
      discard fieldsOf("a:", "\tb: 1")

suite "frontmatter: where an error is":

  test "Given a refusal, when its message is read, then it names the line of the file":
    check "line 3:" in errorOf("---\nname: x\n\tbad: y\n---\n")
    check "line 4:" in errorOf("---\nname: x\n\nname: y\n---\n")
    check "line 5:" in errorOf("---\nname: x\n# c\n\nbare\n---\n")
