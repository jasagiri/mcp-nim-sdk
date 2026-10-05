## The client side of the skills extension: discover the skills a server
## serves, fetch one, and verify what arrives.
##
##   client.declareSkills()                    # before connect()
##   await client.connect(transport)
##   let listing = await client.listAllSkills()
##   let skill = client.openSkill(listing.entries[0])
##   let loaded = await skill.loadInstructions()   # verified SKILL.md
##
## What a skill says is untrusted input. This module fetches and verifies; it
## does not run anything, give effect to a frontmatter field such as
## `allowed-tools`, or decide whether a user approved the skill. A host does
## that with `contentBinding` and the verified content it gets here.
##
## Source: modelcontextprotocol/ext-skills @ 167da6c0d42c247a8f8470228a10ca711e3f6c45
## (SEP-2640, Final), 2026-07-28 and later.

import std/[asyncdispatch, base64, json, options]
import ../../client/client
import ../../client/content
import ../../client/extensions
import ../../client/resources
import ./frontmatter
import ./model

type
  RejectedSkill* = object
    ## A listed entry that breaks the specification's rules and must not be
    ## loaded; reported, never dropped silently.
    uri*: string
      ## What the entry gave as its `uri`, when it gave a string.
    reason*: string

  SkillListing* = object
    entries*: seq[SkillEntry]
    rejected*: seq[RejectedSkill]

  SkillPage* = object
    listing*: SkillListing
    nextCursor*: Option[string]

  DirectoryChild* = object
    uri*: string
    name*: string
    mimeType*: string
    isDirectory*: bool

  LoadedSkill* = object
    ## A SKILL.md that passed verification against its entry.
    entry*: SkillEntry
    frontmatter*: JsonNode
    instructions*: string
      ## What follows the frontmatter: text for the model, untrusted.

  SkillHandle* = ref object
    ## One skill, held under the entry it was opened with: reads resolve only
    ## to what that entry lists, and every byte is checked against it.
    client: McpClient
    entry*: SkillEntry
    allowDynamic: bool
    retrieved: int64

proc declareSkills*(client: McpClient) =
  ## Declare support for the extension. Call before connect(). Only a
  ## 2026-07-28 connection carries it.
  client.declareExtension(SkillsExtensionId)

proc skillsOffered*(client: McpClient): bool =
  ## Whether the connected server declared the extension.
  client.serverExtension(SkillsExtensionId).isSome

proc directoryReadOffered*(client: McpClient): bool =
  ## Whether the server declared `directoryRead: true`.
  let settings = client.serverExtension(SkillsExtensionId)
  settings.isSome and settings.get{"directoryRead"}.getBool()

proc listSkills*(client: McpClient, cursor: Option[string] = none(string),
                 options: McpRequestOptions = McpRequestOptions()): Future[SkillPage] {.async.} =
  ## One page of `skills/list`. An entry that breaks the rules goes to
  ## `rejected` with the reason; the others are validated and usable.
  let reply = await client.callExtension(SkillsExtensionId, SkillsListMethod,
                                         pageParams(cursor), options)
  for item in requiredArray(reply, "skills", SkillsListMethod):
    try:
      result.listing.entries.add parseSkillEntry(item, SkillsListMethod)
    except SkillsError as e:
      result.listing.rejected.add RejectedSkill(
        uri: (if item.kind == JObject: item{"uri"}.getStr() else: ""), reason: e.msg)
  result.nextCursor = parseNextCursor(reply, "skills/list")

proc listAllSkills*(client: McpClient,
                    options: McpRequestOptions = McpRequestOptions()): Future[SkillListing] {.async.} =
  ## Every page of `skills/list`. The listing may be empty or partial without
  ## the server having no skills: a skill can still be fetched by its URI
  ## with `getSkill`.
  var rejected: seq[RejectedSkill]
  result.entries = await allPages[SkillEntry](SkillsListMethod,
    proc(cursor: Option[string]): Future[tuple[items: seq[SkillEntry], next: Option[string]]] {.async.} =
      let page = await client.listSkills(cursor, options)
      rejected.add page.listing.rejected
      return (items: page.listing.entries, next: page.nextCursor))
  result.rejected = rejected

proc getSkill*(client: McpClient, uri: string,
               options: McpRequestOptions = McpRequestOptions()): Future[SkillEntry] {.async.} =
  ## The entry of the skill whose SKILL.md is at `uri`, listed or not.
  ## Raises McpRequestError (-32602) when the server serves no such skill and
  ## McpProtocolError for an entry that breaks the rules or names another URI.
  let reply = await client.callExtension(SkillsExtensionId, SkillsGetMethod,
                                         %*{"uri": uri}, options)
  let node = reply{"skill"}
  if node.isNil:
    raise newException(McpProtocolError, SkillsGetMethod & ": the result has no `skill`")
  try:
    result = parseSkillEntry(node, SkillsGetMethod)
  except SkillsError as e:
    raise newException(McpProtocolError, e.msg)
  if result.uri != uri:
    raise newException(McpProtocolError, SkillsGetMethod & ": asked for " & uri &
                                         " and got the entry of " & result.uri)

proc openSkill*(client: McpClient, entry: SkillEntry, allowDynamic = false): SkillHandle =
  ## Hold `entry` for reading. A skill whose `resources` is "dynamic" cannot
  ## be verified or content-bound, so it is refused unless `allowDynamic`.
  SkillHandle(client: client, entry: entry, allowDynamic: allowDynamic)

proc retrievedBytes*(skill: SkillHandle): int64 =
  skill.retrieved

proc contentBytes(item: McpResourceContent, uri: string): string =
  if item.text.isSome:
    return item.text.get
  if item.blob.isSome:
    try:
      return base64.decode(item.blob.get)
    except ValueError:
      raise newException(McpProtocolError, "resources/read: the blob of " & uri &
                                           " is not base64")
  raise newException(McpProtocolError, "resources/read: " & uri & " has neither text nor blob")

proc readSkillFile*(skill: SkillHandle, uri: string,
               options: McpRequestOptions = McpRequestOptions()): Future[string] {.async.} =
  ## The bytes of one file of the skill, read with `resources/read` and
  ## verified against the held entry. Raises SkillVerificationError for a file
  ## the entry does not list, a size or digest mismatch (the content is not
  ## returned), and SkillsError for a dynamic skill the host did not allow or
  ## a skill beyond the 16 MiB limit.
  let root = skillRootOf(skill.entry.uri)
  var listed = none(SkillResource)
  if skill.entry.dynamic:
    if not skill.allowDynamic:
      raise newException(SkillsError, skill.entry.uri &
        " is dynamic: it offers no content integrity, and this host did not allow it")
    if uri != skill.entry.uri and (root.isNone or relativePathIn(root.get, uri).isNone):
      raise newException(SkillVerificationError, uri & " is not a file of " & skill.entry.uri)
  else:
    listed = skill.entry.find(uri)
    if listed.isNone:
      raise newException(SkillVerificationError,
        uri & " is not listed by the entry of " & skill.entry.uri)
    if skill.retrieved + listed.get.size > MaxSkillBytes:
      raise newException(SkillsError, skill.entry.uri & ": reading " & uri &
                                      " would pass the limit of " & $MaxSkillBytes & " bytes")
  let contents = await skill.client.readResource(uri, options)
  var bytes: string
  var answered = false
  for item in contents:
    if item.uri == uri:
      bytes = contentBytes(item, uri)
      answered = true
      break
  if not answered:
    raise newException(McpProtocolError, "resources/read: the answer does not contain " & uri)
  if skill.retrieved + bytes.len > MaxSkillBytes:
    raise newException(SkillsError, skill.entry.uri & ": the content retrieved passes the limit of " &
                                    $MaxSkillBytes & " bytes")
  if listed.isSome:
    if bytes.len.int64 != listed.get.size:
      raise newException(SkillVerificationError, uri & ": " & $bytes.len &
        " bytes were read and the entry says " & $listed.get.size)
    if digestOf(bytes) != listed.get.digest:
      raise newException(SkillVerificationError, uri & ": the digest does not match the entry")
  skill.retrieved += bytes.len
  return bytes

proc loadInstructions*(skill: SkillHandle,
                       options: McpRequestOptions = McpRequestOptions()): Future[LoadedSkill] {.async.} =
  ## Read the skill's SKILL.md, verify it, and hand over its instructions:
  ## the content must match the entry's digest and size, its YAML frontmatter
  ## must read and equal the entry's `frontmatter`, field by field. Raises
  ## SkillVerificationError otherwise. This is a fetch, not an activation: the
  ## host still owes the skill its approval and its origin tag.
  let text = await skill.readSkillFile(skill.entry.uri, options)
  var parsed: Frontmatter
  try:
    parsed = parseFrontmatter(text)
  except FrontmatterError as e:
    raise newException(SkillVerificationError, skill.entry.uri &
      ": the frontmatter cannot be verified: " & e.msg)
  if parsed.fields != skill.entry.frontmatter:
    raise newException(SkillVerificationError, skill.entry.uri &
      ": the frontmatter of the file differs from the frontmatter of the entry")
  LoadedSkill(entry: skill.entry, frontmatter: parsed.fields, instructions: parsed.body)

proc refreshEntry*(client: McpClient, entry: SkillEntry,
                   options: McpRequestOptions = McpRequestOptions()
                  ): Future[tuple[entry: SkillEntry, changed: bool]] {.async.} =
  ## Fetch the current entry of a skill (after a verification failure, or to
  ## re-check). `changed` is true when its files differ from `entry`'s, which
  ## revokes an approval bound to the old set; a dynamic skill always counts as
  ## changed, since nothing binds it.
  let current = await client.getSkill(entry.uri, options)
  let changed = entry.dynamic or current.dynamic or
                contentBinding(entry) != contentBinding(current)
  return (entry: current, changed: changed)

proc listDirectory*(client: McpClient, uri: string,
                    options: McpRequestOptions = McpRequestOptions()): Future[seq[DirectoryChild]] {.async.} =
  ## The direct children of the directory resource `uri`, through
  ## `resources/directory/read`. Raises McpUnsupportedError, sending nothing,
  ## when the server did not declare `directoryRead: true`. The result is a
  ## live observation, not part of any entry: do not read a child the held
  ## entry does not list (see `listedIn`).
  if not client.directoryReadOffered():
    raise newException(McpUnsupportedError, DirectoryReadMethod &
      ": the server did not declare directoryRead")
  if splitResourceUri(uri).isNone:
    raise newException(SkillsError, "not a safe directory URI: " & uri)
  result = await allPages[DirectoryChild](DirectoryReadMethod,
    proc(cursor: Option[string]): Future[tuple[items: seq[DirectoryChild], next: Option[string]]] {.async.} =
      var params = pageParams(cursor)
      params["uri"] = %uri
      let reply = await client.callExtension(SkillsExtensionId, DirectoryReadMethod,
                                             params, options)
      var children: seq[DirectoryChild]
      for item in requiredArray(reply, "resources", DirectoryReadMethod):
        let childUri = requiredString(item, "uri", DirectoryReadMethod)
        if splitResourceUri(childUri).isNone:
          raise newException(McpProtocolError, DirectoryReadMethod &
            ": the server listed an unsafe URI " & childUri)
        let mime = item{"mimeType"}.getStr()
        children.add DirectoryChild(uri: childUri,
          name: requiredString(item, "name", DirectoryReadMethod), mimeType: mime,
          isDirectory: mime == DirectoryMimeType)
      return (items: children, next: parseNextCursor(reply, DirectoryReadMethod)))

func listedIn*(entry: SkillEntry, children: seq[DirectoryChild]): seq[DirectoryChild] {.raises: [].} =
  ## The children a host may surface for a skill it holds `entry` of: the
  ## directories and the files the entry lists. A file the server added after
  ## the entry was taken is left out; the entry must be refreshed first.
  for child in children:
    if child.isDirectory or entry.dynamic or entry.find(child.uri).isSome:
      result.add child
