## Every external specification (a tagged Scenario in specs/) is verified by a
## test that exists, and what the specs say about implementation agrees with
## src/protocol/implementation_status.nim. See specs/README.md.

import std/[algorithm, os, sets, strutils, tables, unittest]
import protocol/[features, implementation_status]

const Root = currentSourcePath().parentDir.parentDir

type
  Spec = object
    id: string
    file: string
    scenario: string
    feature: string        ## empty: holds for every version
    unimplemented: bool

  Verification = object
    id: string
    testFile: string
    testName: string

proc loadSpecs(): seq[Spec] =
  for path in walkFiles(Root / "specs" / "*.feature"):
    var tags: seq[string]
    for rawLine in readFile(path).splitLines:
      let line = rawLine.strip
      if line.startsWith("@"):
        tags.add line.splitWhitespace
      elif line.startsWith("Scenario"):
        var spec = Spec(file: extractFilename(path),
                        scenario: line.split(":", maxsplit = 1)[1].strip)
        for tag in tags:
          if tag.startsWith("@spec:"):
            spec.id = tag["@spec:".len .. ^1]
          elif tag.startsWith("@feature:"):
            spec.feature = tag["@feature:".len .. ^1]
          elif tag == "@unimplemented":
            spec.unimplemented = true
        result.add spec
        tags = @[]
  result.sort(proc(a, b: Spec): int = cmp(a.id, b.id))

proc loadVerifications(): seq[Verification] =
  for line in readFile(Root / "specs" / "tests.map").splitLines:
    if line.strip.len == 0:
      continue
    let cells = line.split(" | ", maxsplit = 2)
    doAssert cells.len == 3, "tests.map line is not 'ID | file | name': " & line
    result.add Verification(id: cells[0].strip, testFile: cells[1].strip,
                            testName: cells[2].strip)

func featureNamed(name: string): McpFeature =
  for feature in McpFeature:
    if $feature == name:
      return feature
  raise newException(ValueError, "no such feature: " & name)

func testExists(source, name: string): bool =
  ## A test is named by a literal, or by a literal with `<version>` where a
  ## loop puts the protocol version in (`"... version " & $v & ", when ..."`).
  let parts = name.split("<version>")
  if parts.len == 1:
    return ("test \"" & name & "\":") in source
  ("test \"" & parts[0] & "\"") in source and ("\"" & parts[1] & "\":") in source

let specs = loadSpecs()
let verifications = loadVerifications()

suite "external specifications and their tests":

  test "Given the Scenarios in specs/, when their tags are read, then each has a specification identifier and no identifier repeats":
    check specs.len > 0
    var seen = initHashSet[string]()
    for spec in specs:
      checkpoint spec.file & ": " & spec.scenario
      check spec.id.startsWith("MCP-")
      check spec.id notin seen
      seen.incl spec.id

  test "Given a Scenario tied to a feature, when the feature is looked up, then it is a row of the feature table":
    for spec in specs:
      if spec.feature.len > 0:
        checkpoint spec.id & ": " & spec.feature
        discard featureNamed(spec.feature)

  test "Given a specification that is not marked unimplemented, when tests.map is read, then at least one test verifies it":
    var verified = initHashSet[string]()
    for v in verifications:
      verified.incl v.id
    for spec in specs:
      checkpoint spec.id & " in " & spec.file
      if not spec.unimplemented:
        check spec.id in verified

  test "Given a specification marked unimplemented, when tests.map is read, then no test is listed for it":
    var verified = initHashSet[string]()
    for v in verifications:
      verified.incl v.id
    for spec in specs:
      if spec.unimplemented:
        checkpoint spec.id
        check spec.id notin verified

  test "Given a line of tests.map, when its identifier and test are looked up, then both exist":
    var ids = initTable[string, Spec]()
    for spec in specs:
      ids[spec.id] = spec
    for v in verifications:
      checkpoint v.id & " -> " & v.testFile & ": " & v.testName
      check v.id in ids
      check fileExists(Root / v.testFile)
      if fileExists(Root / v.testFile):
        check testExists(readFile(Root / v.testFile), v.testName)

  test "Given a tests.map, when read, then no line is repeated":
    var seen = initHashSet[string]()
    for v in verifications:
      let key = v.id & "|" & v.testFile & "|" & v.testName
      check key notin seen
      seen.incl key

  test "Given a Scenario tied to a feature, when compared with the implementation status, then implemented and unimplemented agree":
    for spec in specs:
      if spec.feature.len > 0:
        checkpoint spec.id & ": " & spec.feature
        let status = implementationOf(featureNamed(spec.feature)).status
        check (status == isImplemented) == (not spec.unimplemented)

  test "Given a feature the SDK implements, when the Scenarios are read, then at least one Scenario is tied to it":
    var tied = initHashSet[string]()
    for spec in specs:
      if spec.feature.len > 0 and not spec.unimplemented:
        tied.incl spec.feature
    for feature in McpFeature:
      if implementationOf(feature).status == isImplemented:
        checkpoint $feature
        check $feature in tied
