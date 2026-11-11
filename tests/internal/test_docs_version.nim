## The generated README and docs agree with the protocol version of the build,
## with the feature table and with what is implemented.
##
## `nimble genDocs` writes the files; `nimble testAllVersions` writes them again
## for each version before it runs the tests of that version.

import std/[os, sets, strutils, unittest]
import protocol/[version, features, feature_docs, implementation_status]
import ../../tools/gen_docs

const Root = currentSourcePath().parentDir.parentDir.parentDir

func tableRows(markdown: string): seq[seq[string]] =
  ## The cells of the feature table's rows, without header and separator.
  var inTable = false
  for line in markdown.splitLines:
    if line.startsWith("| Feature |"):
      inTable = true
    elif inTable and line.startsWith("|---"):
      discard
    elif inTable and line.startsWith("| "):
      var cells: seq[string]
      for cell in line.split(" | "):
        cells.add cell.strip(chars = {'|', ' '})
      result.add cells
    else:
      inTable = false

func headings(markdown: string): seq[string] =
  for line in markdown.splitLines:
    if line.startsWith("## "):
      result.add line[3 .. ^1]

func sectionOf(markdown, headingStart: string): string =
  ## The lines under the `## ` heading that starts with `headingStart`, up to
  ## the next `## ` heading.
  var inside = false
  for line in markdown.splitLines:
    if line.startsWith("## "):
      inside = line[3 .. ^1].startsWith(headingStart)
    elif inside:
      result.add line & "\n"

func fileNamed(files: seq[GeneratedFile], path: string): string =
  for file in files:
    if file.path == path:
      return file.content
  raise newException(ValueError, "not generated: " & path)

func namesOf(version: McpProtocolVersion): HashSet[string] =
  for feature in featuresOf(version):
    result.incl displayName(feature)

suite "generated documentation":

  test "Given the files on disk, when compared with what the generator makes for the build's default version, then they are identical":
    for file in generate(Root):
      check fileExists(Root / file.path)
      if fileExists(Root / file.path):
        checkpoint "stale: " & file.path & " (run nimble genDocs)"
        check readFile(Root / file.path) == file.content

  test "Given the documents of two versions, when compared, then they differ, so a forgotten regeneration shows up in the comparison with the disk":
    let current = fileNamed(generate(Root), "README.md")
    for other in McpProtocolVersion:
      if other != DefaultProtocolVersion:
        check current != fileNamed(generate(Root, other), "README.md")

  test "Given the README on disk, when it names the version its features belong to, then it is the build's default":
    let readme = readFile(Root / "README.md")
    var named: seq[string]
    for heading in headings(readme):
      if heading.startsWith("Features of "):
        named.add heading["Features of ".len .. ^1]
    check named == @[$DefaultProtocolVersion]
    check ("**" & $DefaultProtocolVersion & "**") in readme

  for v in McpProtocolVersion:
    test "Given the documents generated for " & $v & ", when read, then the README lists exactly the features of " & $v & " and each docs section is one of them":
      let files = generate(Root, v)
      let readme = fileNamed(files, "README.md")
      check ("**" & $v & "**") in readme
      check ("`mcp-" & $v & "`") in readme

      # The README has other tables; the features are the ones of this section.
      let featureRows = tableRows(sectionOf(readme, "Features of "))
      var listed: HashSet[string]
      for row in featureRows:
        listed.incl row[0]
      check listed == namesOf(v)

      for row in featureRows:
        for feature in featuresOf(v):
          if displayName(feature) == row[0]:
            check row[1].startsWith($implementationOf(feature).status)

      for path in ["docs/features.md", "docs/transports.md"]:
        for heading in headings(fileNamed(files, path)):
          checkpoint path & ": " & heading
          check heading in namesOf(v) or heading in ["stdio", "Streamable HTTP", "HTTP+SSE"]

  test "Given a version without Streamable HTTP, when docs are generated, then no page presents it":
    let files = generate(Root, mpv20241105)
    check "Streamable" notin fileNamed(files, "README.md")
    check "Streamable" notin fileNamed(files, "docs/index.md")
    check "Streamable" notin fileNamed(files, "docs/transports.md")
    check "http_server.nim" notin fileNamed(files, "README.md")

  test "Given a feature the table marks implemented, when its evidence is read, then every named test file exists":
    for feature in McpFeature:
      let impl = implementationOf(feature)
      check (impl.status == isImplemented) == (impl.evidence.len > 0)
      for evidence in impl.evidence:
        checkpoint $feature & ": " & evidence
        check fileExists(Root / evidence)

  # Not tied to a specification: the MCP specification asks clients and
  # servers, that is the applications, to document their dialects, and the
  # SDK helps them by naming its own in the README. Whether the README is
  # right depends on what the validator takes, so this is a check that the
  # documentation agrees with the implementation; what the validator takes is
  # MCP-SCHEMA-1 and MCP-SCHEMA-2. Until 2026-10-17 this was the specification
  # MCP-CONTENT-FIELDS-15.
  test "Given the dialects the validator takes, when the README is read, then it names each of them and what happens to any other":
    let readme = readFile(Root / "README.md")
    check "JSON Schema 2020-12" in readme
    check "draft-07" in readme
    check "UnsupportedDialectError" in readme

  test "Given templates with a mistake, when rendered, then ValueError names it instead of producing a page":
    expect ValueError: discard render("{{#if ftNoSuchFeature}}\nx\n{{/if}}", Root, mpv20260728)
    expect ValueError: discard render("{{#if ftTools}}\nx", Root, mpv20260728)
    expect ValueError: discard render("x\n{{/if}}", Root, mpv20260728)
    expect ValueError: discard render("{{no_such_variable}}", Root, mpv20260728)

  test "Given a spoken condition, when rendered, then a feature of an earlier version keeps its lines and one no spoken version has hides them":
    # Tasks are core in 2025-11-25 alone: a 2026-07-28 build still speaks them.
    let text = "{{#if spoken:ftTasks}}\ntasks\n{{/if}}\n{{#if ftTasks}}\nnow\n{{/if}}\n"
    check render(text, ".", mpv20260728) == "tasks\n"
    check render(text, ".", mpv20251125) == "tasks\nnow\n"
    check render(text, ".", mpv20250618) == ""
    check render("{{#if !spoken:ftTasks}}\nnone\n{{/if}}\n", ".", mpv20250618) == "none\n"

  test "Given an ext condition, when rendered, then its lines show only where the checkout has that extension module":
    let text = "{{#if ext:tasks}}\nT\n{{/if}}\n{{#if !ext:tasks}}\nnone\n{{/if}}\n{{#if ext:no_such_extension}}\nX\n{{/if}}\n"
    let expected = if fileExists(Root / "src" / "ext" / "tasks.nim"): "T\n" else: "none\n"
    check render(text, Root, mpv20260728) == expected
    expect ValueError: discard render("{{#if ext:../protocol/version}}\nX\n{{/if}}\n", Root, mpv20260728)

  test "Given conditions, when rendered, then a feature the version lacks hides its lines":
    let text = "{{#if ftDiscover}}\nA\n{{/if}}\n{{#if !ftDiscover}}\nB\n{{/if}}"
    check render(text, Root, mpv20260728) == "A"
    check render(text, Root, mpv20250618) == "B"
