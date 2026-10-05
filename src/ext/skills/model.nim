## What the skills extension puts on the wire: skill entries with their
## manifests, the URI and name rules a skill must follow, and the checks that
## turn an entry from the network (untrusted) into one the rest of the SDK
## can use.
##
## Source: modelcontextprotocol/ext-skills @ 167da6c0d42c247a8f8470228a10ca711e3f6c45,
## specification/stable/skills.mdx (SEP-2640, Final), written against the
## base protocol revision 2026-07-28. The skill format itself (SKILL.md,
## `name` and `description` rules) is the Agent Skills specification,
## https://agentskills.io/specification.

import std/[algorithm, json, options, os, sequtils, strutils, unicode, uri]
import ../../auth/oauth/sha256

const
  SkillsExtensionId* = "io.modelcontextprotocol/skills"
  SkillsListMethod* = "skills/list"
  SkillsGetMethod* = "skills/get"
  DirectoryReadMethod* = "resources/directory/read"
  DefaultSkillScheme* = "skill"
  SkillFileName* = "SKILL.md"
  DirectoryMimeType* = "inode/directory"
  MaxResourcesPerSkill* = 512
    ## The per-skill limits every conforming host accepts (spec: Limits).
  MaxSkillBytes* = 16_777_216'i64
  MaxNameLength = 64
  MaxDescriptionLength = 1024
  DigestPrefix = "sha256:"

type
  SkillsError* = object of CatchableError
    ## An entry, a name, a path or a file that breaks the extension's rules.

  SkillVerificationError* = object of SkillsError
    ## Fetched content is not what the held entry described: a digest or
    ## size mismatch, a frontmatter discrepancy, or a file the entry does not
    ## list. The content must not be used.

  SkillResource* = object
    ## A file of a skill, with the digest and size of its raw bytes.
    uri*: string
    digest*: string
      ## `sha256:` and 64 lowercase hexadecimal characters.
    size*: int64

  SkillEntry* = object
    ## The entry of one skill, as `skills/list` and `skills/get` return it.
    uri*: string
      ## The URI of the skill's SKILL.md.
    frontmatter*: JsonNode
      ## The SKILL.md frontmatter as a JSON object; `name` and `description`
      ## are always strings.
    dynamic*: bool
      ## `resources` is the string "dynamic": the content is generated and no
      ## stable digests exist. Such a skill offers no content integrity.
    resources*: seq[SkillResource]
      ## Every file, SKILL.md included; empty when `dynamic`.

func skillName*(entry: SkillEntry): string {.raises: [].} =
  entry.frontmatter{"name"}.getStr()

func digestOf*(content: string): string {.raises: [].} =
  ## `sha256:{hex}` of the raw bytes of `content`.
  DigestPrefix & sha256(content).toHex()

func isDigest(text: string): bool {.raises: [].} =
  text.len == DigestPrefix.len + 64 and text.startsWith(DigestPrefix) and
    text[DigestPrefix.len .. ^1].allCharsInSet({'0' .. '9', 'a' .. 'f'})

func validateSkillName*(name: string): Option[string] {.raises: [].} =
  ## Why `name` is not a skill name under the Agent Skills specification
  ## (1-64 characters, lowercase letters, digits and hyphens, no leading,
  ## trailing or doubled hyphen), or none when it is.
  if name.len == 0:
    return some("a skill name is empty")
  if name.runeLen > MaxNameLength:
    return some("a skill name is at most " & $MaxNameLength & " characters")
  if name[0] == '-' or name[^1] == '-':
    return some("a skill name does not start or end with a hyphen")
  if "--" in name:
    return some("a skill name has no consecutive hyphens")
  if name.toLower() != name:
    return some("a skill name is lowercase")
  for rune in name.runes:
    if rune.int < 128:
      if char(rune.int) notin {'a' .. 'z', '0' .. '9', '-'}:
        return some("a skill name holds letters, digits and hyphens only")
    elif not rune.isAlpha:
      return some("a skill name holds letters, digits and hyphens only")
  none(string)

func validateDescription*(description: string): Option[string] {.raises: [].} =
  if description.len == 0:
    some("a skill description is empty")
  elif description.runeLen > MaxDescriptionLength:
    some("a skill description is at most " & $MaxDescriptionLength & " characters")
  else:
    none(string)

# URIs and paths. Every path that comes out of a URI is checked segment by
# segment before anything uses it: the names the network supplies are never
# joined into a filesystem path as they are.

func isSchemeName(scheme: string): bool {.raises: [].} =
  scheme.len > 0 and scheme[0] in Letters and
    scheme.allCharsInSet(Letters + Digits + {'+', '-', '.'})

func isSafeSegment(segment: string): bool {.raises: [].} =
  ## A path segment that cannot climb out of, or stand for, a directory.
  if segment.len == 0 or segment == "." or segment == "..":
    return false
  for c in segment:
    if c in {'\\', '\0', '?', '#'} or c < ' ' or c == '\x7f':
      return false
  # An escaped form must not turn into a separator or a dot segment.
  if '%' in segment:
    var decoded: string
    try:
      decoded = decodeUrl(segment, decodePlus = false)
    except ValueError:
      return false
    if decoded == "." or decoded == ".." or '/' in decoded or '\\' in decoded or
       '\0' in decoded:
      return false
  true

func splitResourceUri*(uri: string): Option[tuple[scheme, path: string]] {.raises: [].} =
  ## The scheme and the `/`-separated path (the authority is the first
  ## segment) of `scheme://a/b/c`, when every segment is safe. No query, no
  ## fragment, no trailing slash.
  let marker = uri.find("://")
  if marker <= 0:
    return none(tuple[scheme, path: string])
  let scheme = uri[0 ..< marker]
  let path = uri[marker + 3 .. ^1]
  if not isSchemeName(scheme) or path.len == 0:
    return none(tuple[scheme, path: string])
  for segment in path.split('/'):
    if not isSafeSegment(segment):
      return none(tuple[scheme, path: string])
  some((scheme: scheme, path: path))

func skillRootOf*(skillUri: string): Option[string] {.raises: [].} =
  ## The directory URI of the skill whose SKILL.md is `skillUri`: the URI
  ## without `/SKILL.md`.
  let suffix = "/" & SkillFileName
  if not skillUri.endsWith(suffix):
    return none(string)
  let root = skillUri[0 ..< skillUri.len - suffix.len]
  if splitResourceUri(root).isNone:
    return none(string)
  some(root)

func relativePathIn*(rootUri, fileUri: string): Option[string] {.raises: [].} =
  ## The path of `fileUri` below the directory `rootUri`, when it lies
  ## strictly inside it and every segment is safe.
  let prefix = rootUri & "/"
  if not fileUri.startsWith(prefix) or fileUri.len == prefix.len:
    return none(string)
  let relative = fileUri[prefix.len .. ^1]
  for segment in relative.split('/'):
    if not isSafeSegment(segment):
      return none(string)
  some(relative)

func safeFilePath*(path: string): bool {.raises: [].} =
  ## A relative file path a server may name inside a skill.
  path.len > 0 and path[0] != '/' and path.split('/').allIt(isSafeSegment(it))

func skillStoragePath*(storageRoot, serverLabel, uri: string): string {.raises: [SkillsError].} =
  ## Where a host may keep the file at `uri` of the server it labels
  ## `serverLabel`, below `storageRoot`. The label (host-assigned, never the
  ## server's own claim) and the URI both appear in the path, so two servers
  ## that serve the same URI land apart. Raises SkillsError for a label or
  ## URI that is unsafe, or when the result would leave `storageRoot`.
  if serverLabel.len == 0 or serverLabel == "." or serverLabel == "..":
    raise newException(SkillsError, "the server label is not usable as a directory name")
  let parts = splitResourceUri(uri)
  if parts.isNone:
    raise newException(SkillsError, "not a safe resource URI: " & uri)
  let root = normalizedPath(storageRoot)
  var target = root / encodeUrl(serverLabel, usePlus = false) /
    encodeUrl(parts.get.scheme, usePlus = false)
  for segment in parts.get.path.split('/'):
    target = target / encodeUrl(segment, usePlus = false)
  target = normalizedPath(target)
  if not target.startsWith(root & DirSep):
    raise newException(SkillsError, "the path of " & uri & " leaves " & storageRoot)
  target

# Entries.

func toJson*(resource: SkillResource): JsonNode {.raises: [].} =
  %*{"uri": resource.uri, "digest": resource.digest, "size": resource.size}

func toJson*(entry: SkillEntry): JsonNode {.raises: [].} =
  result = %*{"uri": entry.uri, "frontmatter": entry.frontmatter}
  if entry.dynamic:
    result["resources"] = %"dynamic"
  else:
    var resources = newJArray()
    for resource in entry.resources:
      resources.add resource.toJson()
    result["resources"] = resources

func contentBinding*(entry: SkillEntry): string {.raises: [].} =
  ## What a persisted approval is bound to: the digest of the sorted
  ## `uri`/`digest` pairs of the entry. A different value means the skill
  ## changed and the approval is revoked. Empty for a dynamic skill, which
  ## cannot be bound.
  if entry.dynamic:
    return ""
  var pairs: seq[string]
  for resource in entry.resources:
    pairs.add resource.uri & "\n" & resource.digest
  pairs.sort()
  digestOf(pairs.join("\n"))

func fieldError(context, message: string): ref SkillsError =
  newException(SkillsError, context & ": " & message)

proc parseSkillEntry*(node: JsonNode, context: string): SkillEntry {.raises: [SkillsError].} =
  ## An entry received from a server, validated against every rule the
  ## specification gives for entries: raises SkillsError (naming the rule)
  ## for any entry a host must not load.
  if node.isNil or node.kind != JObject:
    raise fieldError(context, "an entry is not an object")
  let uriNode = node{"uri"}
  if uriNode.isNil or uriNode.kind != JString:
    raise fieldError(context, "an entry needs a string `uri`")
  result.uri = uriNode.getStr()
  let root = skillRootOf(result.uri)
  if root.isNone:
    raise fieldError(context, "`uri` must be a safe resource URI ending in /" &
                              SkillFileName & ": " & result.uri)
  let frontmatter = node{"frontmatter"}
  if frontmatter.isNil or frontmatter.kind != JObject:
    raise fieldError(context, "an entry needs a `frontmatter` object")
  for key in ["name", "description"]:
    if frontmatter{key}.isNil or frontmatter{key}.kind != JString:
      raise fieldError(context, "`frontmatter." & key & "` must be a string")
  result.frontmatter = frontmatter
  let name = frontmatter{"name"}.getStr()
  let nameProblem = validateSkillName(name)
  if nameProblem.isSome:
    raise fieldError(context, nameProblem.get & ": " & name)
  let descriptionProblem = validateDescription(frontmatter{"description"}.getStr())
  if descriptionProblem.isSome:
    raise fieldError(context, descriptionProblem.get)
  let lastSegment = root.get[root.get.rfind('/') + 1 .. ^1]
  if lastSegment != name:
    raise fieldError(context, "the last path segment '" & lastSegment &
                              "' of the URI must equal the skill name '" & name & "'")
  let resources = node{"resources"}
  if resources.isNil:
    raise fieldError(context, "an entry needs `resources`")
  if resources.kind == JString:
    if resources.getStr() != "dynamic":
      raise fieldError(context, "`resources` is a string other than \"dynamic\"")
    result.dynamic = true
    return
  if resources.kind != JArray:
    raise fieldError(context, "`resources` must be an array or \"dynamic\"")
  if resources.len > MaxResourcesPerSkill:
    raise fieldError(context, $resources.len & " resources exceed the limit of " &
                              $MaxResourcesPerSkill)
  var seen: seq[string]
  var total = 0'i64
  var listsSkillMd = false
  for item in resources:
    if item.kind != JObject:
      raise fieldError(context, "a resource is not an object")
    let uri = item{"uri"}
    let digest = item{"digest"}
    let size = item{"size"}
    if uri.isNil or uri.kind != JString or digest.isNil or digest.kind != JString or
       size.isNil or size.kind != JInt:
      raise fieldError(context, "a resource needs a string `uri`, a string `digest` " &
                                "and an integer `size`")
    if not isDigest(digest.getStr()):
      raise fieldError(context, "malformed digest " & digest.getStr())
    if size.getBiggestInt() < 0:
      raise fieldError(context, "a negative size for " & uri.getStr())
    let isSkillMd = uri.getStr() == result.uri
    if not isSkillMd and relativePathIn(root.get, uri.getStr()).isNone:
      raise fieldError(context, uri.getStr() & " is not a file of the skill at " & root.get)
    if uri.getStr() in seen:
      raise fieldError(context, uri.getStr() & " is listed twice")
    seen.add uri.getStr()
    listsSkillMd = listsSkillMd or isSkillMd
    total += size.getBiggestInt()
    if total > MaxSkillBytes:
      raise fieldError(context, "the files exceed the limit of " & $MaxSkillBytes & " bytes")
    result.resources.add SkillResource(uri: uri.getStr(), digest: digest.getStr(),
                                       size: size.getBiggestInt())
  if not listsSkillMd:
    raise fieldError(context, "`resources` does not list the SKILL.md itself")

func find*(entry: SkillEntry, uri: string): Option[SkillResource] {.raises: [].} =
  for resource in entry.resources:
    if resource.uri == uri:
      return some(resource)
  none(SkillResource)
