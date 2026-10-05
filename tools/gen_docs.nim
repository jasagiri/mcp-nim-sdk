## Writes README.md and docs/*.md from templates/ for the protocol version
## this build speaks (`DefaultProtocolVersion`).
##
##   nimble genDocs
##   nim r -d:mcpDefaultProtocolVersion=2025-06-18 tools/gen_docs.nim
##
## Every output has one template, listed in `Pages`. Which features a page
## may mention comes from `src/protocol/features.nim`; whether they work comes
## from `src/protocol/implementation_status.nim`.
##
## Template syntax, one directive per line:
##
##   {{name}}                 a variable (see `variablesFor`); `{{status:ftTools}}`
##                            is the implementation status of a feature
##   {{include path}}         the text of a file, relative to the repository root
##   {{#if cond}} ... {{/if}} the lines in between, when `cond` holds
##
## `cond` is a feature (`ftTools`), `spoken:` and a feature, `modern`,
## `legacy` or `all`, optionally prefixed with `!`. A feature holds when the
## version has it; `spoken:ftTasks` holds when the version or an earlier one
## has it, which is what a build that speaks them all can do. `modern` holds
## when the build speaks 2026-07-28 or later.

import std/[os, strformat, strutils, tables]
import protocol/[version, features, implementation_status]

const
  Root = currentSourcePath().parentDir.parentDir
  SpecificationSite = "https://modelcontextprotocol.io/specification/"
  RepositoryUrl = "https://github.com/jasagiri/mcp-nim-sdk"

type
  Page* = object
    source*: string    ## relative to the repository root
    output*: string     ## relative to the repository root

  GeneratedFile* = object
    path*: string       ## relative to the repository root
    content*: string

const Pages* = [
  Page(source: "templates/README.md", output: "README.md"),
  Page(source: "templates/docs/index.md", output: "docs/index.md"),
  Page(source: "templates/docs/versions.md", output: "docs/versions.md"),
  Page(source: "templates/docs/transports.md", output: "docs/transports.md"),
  Page(source: "templates/docs/features.md", output: "docs/features.md")]

func specUrl(feature: McpFeature, version: McpProtocolVersion): string =
  var page = specPage(feature, version)
  page.removeSuffix("/index")
  SpecificationSite & $version & "/" & page

func statusText(feature: McpFeature): string =
  let impl = implementationOf(feature)
  result = $impl.status
  if impl.note.len > 0:
    result.add " (" & impl.note & ")"

func featureTable*(version: McpProtocolVersion): string =
  ## One row per feature of `version`: `| name | status | specification |`.
  var rows = @["| Feature | Status | Specification |", "|---|---|---|"]
  for feature in featuresOf(version):
    var page = specPage(feature, version)
    page.removeSuffix("/index")
    rows.add &"| {displayName(feature)} | {statusText(feature)} | [{page}]({specUrl(feature, version)}) |"
  rows.join("\n")

func versionTable(ceiling: McpProtocolVersion): string =
  var rows = @["| Version | Branch | Handshake | This build |", "|---|---|---|---|"]
  for v in McpProtocolVersion:
    let handshake = if v.isModern: "none, every request carries its metadata"
                    else: "`initialize`"
    let spoken = if v <= ceiling: "speaks" else: "does not speak"
    rows.add &"| `{v}` | `mcp-{v}` | {handshake} | {spoken} |"
  rows.join("\n")

func implementedSummary(version: McpProtocolVersion): string =
  var implemented = 0
  let all = featuresOf(version)
  for feature in all:
    if implementationOf(feature).status == isImplemented:
      inc implemented
  &"{implemented} of the {all.len} features of `{version}` are implemented in this tree."

func variablesFor*(version: McpProtocolVersion): Table[string, string] =
  var spoken: seq[string]
  for v in versionsUpTo(version):
    spoken.add "`" & $v & "`"
  for feature in McpFeature:
    result["status:" & $feature] = statusText(feature)
  for (name, value) in {"version": $version,
   "branch": "mcp-" & $version,
   "repository": RepositoryUrl,
   "spoken_versions": spoken.join(", "),
   "version_table": versionTable(version),
   "feature_table": featureTable(version),
   "implemented_summary": implementedSummary(version)}:
    result[name] = value

func holds(cond: string, version: McpProtocolVersion): bool =
  if cond.startsWith("!"):
    return not holds(cond[1 .. ^1], version)
  case cond
  of "all": true
  of "modern": version.isModern
  of "legacy": true  # every build speaks the first version, which is legacy
  else:
    # `spoken:ftX`: some version the build speaks has the feature, though
    # `version` itself may have dropped it.
    let spoken = cond.startsWith("spoken:")
    let name = if spoken: cond["spoken:".len .. ^1] else: cond
    for feature in McpFeature:
      if $feature == name:
        if not spoken:
          return version.has(feature)
        for earlier in versionsUpTo(version):
          if earlier.has(feature):
            return true
        return false
    raise newException(ValueError, "unknown condition: " & cond)

proc render*(templateText, root: string, version: McpProtocolVersion): string =
  ## `templateText` with its directives resolved for `version`. Raises
  ## ValueError for a directive that does not resolve, so a typo in a template
  ## stops the run instead of reaching a reader.
  let variables = variablesFor(version)
  var active: seq[bool]
  var lines: seq[string]
  for rawLine in templateText.splitLines:
    let line = rawLine.strip
    if line.startsWith("{{#if ") and line.endsWith("}}"):
      active.add holds(line[6 .. ^3].strip, version)
    elif line == "{{/if}}":
      if active.len == 0:
        raise newException(ValueError, "{{/if}} without {{#if}}")
      discard active.pop
    elif false in active:
      discard
    elif line.startsWith("{{include ") and line.endsWith("}}"):
      lines.add readFile(root / line[10 .. ^3].strip).strip(chars = {'\n'})
    else:
      var text = rawLine
      for name, value in variables:
        text = text.replace("{{" & name & "}}", value)
      let open = text.find("{{")
      if open >= 0:
        raise newException(ValueError, "unresolved directive in: " & text)
      lines.add text
  if active.len > 0:
    raise newException(ValueError, "{{#if}} without {{/if}}")
  lines.join("\n")

proc generate*(root = Root, version = DefaultProtocolVersion): seq[GeneratedFile] =
  for page in Pages:
    let body = render(readFile(root / page.source), root, version)
    let header = "<!-- Generated by tools/gen_docs.nim from " & page.source &
      ". Edit the template, not this file. -->\n\n"
    result.add GeneratedFile(path: page.output, content: header & body)

when isMainModule:
  for file in generate():
    writeFile(Root / file.path, file.content)
    echo "wrote ", file.path
