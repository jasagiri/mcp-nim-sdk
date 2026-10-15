## The server side of the skills extension: a catalog of skills a server
## serves, and `registerSkills`, which declares the extension and answers
## `skills/list`, `skills/get`, `resources/read` of the skills' files and,
## when asked to, `resources/directory/read`.
##
##   let catalog = newSkillCatalog()
##   catalog.addSkill("git-workflow", [SkillFile(path: "SKILL.md", content: text)])
##   server.registerSkills(catalog)
##
## Nothing is served until `registerSkills` is called. The SDK only serves the
## bytes it was given; it never runs a skill.
##
## Source: modelcontextprotocol/ext-skills @ 167da6c0d42c247a8f8470228a10ca711e3f6c45
## (SEP-2640, Final), 2026-07-28 and later.

import std/[asyncdispatch, base64, json, options, os, sets, strutils,
            tables, unicode]
import ../../server/server
import ../../server/extensions
import ../../protocol/modern
import ../../protocol/types
import ./frontmatter
import ./model
import ../official_common

type
  SkillFile* = object
    path*: string
      ## Relative to the skill directory, `/`-separated: `SKILL.md`,
      ## `references/GUIDE.md`.
    content*: string
      ## The raw bytes of the file.
    mimeType*: string
      ## Left empty: chosen from the file extension.

  DynamicSkillFiles* = proc(): Future[seq[SkillFile]] {.closure.}
    ## The files of a skill whose content is generated, as they are right now.

  StoredFile = object
    content: string
    mimeType: string
    digest: string

  CatalogSkill = object
    path: string
    frontmatter: JsonNode
    files: DynamicSkillFiles
      ## nil for a skill with fixed content.

  SkillCatalog* = ref object
    scheme: string
    stored: OrderedTable[string, StoredFile]
      ## Every fixed file, by its path below `scheme://`.
    skills: seq[CatalogSkill]
    cache*: CachePolicy
      ## The `ttlMs` and `cacheScope` of `skills/list` and `skills/get`, which
      ## the specification makes required. Uncached unless the author says
      ## otherwise: a catalog can change between calls.
    pageSize*: int
      ## Skills per `skills/list` page; 0 puts them all on one page.

func mimeTypeOf(path: string): string =
  case path.splitFile.ext.toLowerAscii()
  of ".md", ".markdown": "text/markdown"
  of ".txt": "text/plain"
  of ".json": "application/json"
  of ".yaml", ".yml": "application/yaml"
  of ".csv": "text/csv"
  of ".html", ".htm": "text/html"
  of ".js": "text/javascript"
  of ".py": "text/x-python"
  of ".sh": "text/x-shellscript"
  of ".nim": "text/x-nim"
  of ".png": "image/png"
  of ".jpg", ".jpeg": "image/jpeg"
  of ".gif": "image/gif"
  of ".svg": "image/svg+xml"
  of ".pdf": "application/pdf"
  else: "application/octet-stream"

proc newSkillCatalog*(scheme = DefaultSkillScheme, cache = UncachedPolicy,
                      pageSize = 0): SkillCatalog =
  ## An empty catalog whose URIs use `scheme` (`skill` unless the server's
  ## domain has a native one).
  if scheme.len == 0 or scheme[0] notin Letters or
     not scheme.allCharsInSet(Letters + Digits + {'+', '-', '.'}):
    raise newException(SkillsError, "'" & scheme & "' is not a URI scheme")
  SkillCatalog(scheme: scheme, cache: cache, pageSize: pageSize)

func skillCount*(catalog: SkillCatalog): int =
  catalog.skills.len

func uriOf(catalog: SkillCatalog, path: string): string =
  catalog.scheme & "://" & path

func skillUri(catalog: SkillCatalog, skill: CatalogSkill): string =
  catalog.uriOf(skill.path & "/" & SkillFileName)

proc checkSkillPath(skillPath: string): string =
  ## The skill name, which is the last segment of the path.
  if splitResourceUri("skill://" & skillPath).isNone:
    raise newException(SkillsError, "'" & skillPath & "' is not a safe skill path")
  skillPath[skillPath.rfind('/') + 1 .. ^1]

proc checkFrontmatter(skillPath: string, fields: JsonNode, name: string) =
  for key in ["name", "description"]:
    if fields{key}.isNil or fields{key}.kind != JString:
      raise newException(SkillsError, skillPath & ": the frontmatter needs a string `" &
                                      key & "`")
  let problem = validateSkillName(fields["name"].getStr())
  if problem.isSome:
    raise newException(SkillsError, skillPath & ": " & problem.get)
  if fields["name"].getStr() != name:
    raise newException(SkillsError, skillPath & ": the frontmatter name '" &
      fields["name"].getStr() & "' must equal the last path segment '" & name & "'")
  let descriptionProblem = validateDescription(fields["description"].getStr())
  if descriptionProblem.isSome:
    raise newException(SkillsError, skillPath & ": " & descriptionProblem.get)

proc checkLimits(skillPath: string, count: int, bytes: int64) =
  if count > MaxResourcesPerSkill:
    raise newException(SkillsError, skillPath & ": " & $count & " files exceed the limit of " &
                                    $MaxResourcesPerSkill)
  if bytes > MaxSkillBytes:
    raise newException(SkillsError, skillPath & ": " & $bytes & " bytes exceed the limit of " &
                                    $MaxSkillBytes)

proc addSkill*(catalog: SkillCatalog, skillPath: string, files: openArray[SkillFile]) =
  ## Serve the skill at `skillPath` (`git-workflow`, `acme/billing/refunds`):
  ## its last segment is the skill name. `files` must hold `SKILL.md`, whose
  ## frontmatter supplies the entry's. Raises SkillsError for an unsafe path,
  ## a frontmatter that does not name the skill, a file served twice, or a
  ## skill beyond the limits (512 files, 16 MiB) that no host promises to load.
  let name = checkSkillPath(skillPath)
  var skillMd = none(string)
  var total = 0'i64
  var seen = initHashSet[string]()
  for file in files:
    if not safeFilePath(file.path):
      raise newException(SkillsError, skillPath & ": '" & file.path & "' is not a safe file path")
    if file.path in seen:
      raise newException(SkillsError, skillPath & ": '" & file.path & "' is given twice")
    seen.incl file.path
    total += file.content.len
    if file.path == SkillFileName:
      skillMd = some(file.content)
  if skillMd.isNone:
    raise newException(SkillsError, skillPath & ": the files do not include " & SkillFileName)
  checkLimits(skillPath, files.len, total)
  var parsed: Frontmatter
  try:
    parsed = parseFrontmatter(skillMd.get)
  except FrontmatterError as e:
    raise newException(SkillsError, skillPath & ": " & e.msg)
  checkFrontmatter(skillPath, parsed.fields, name)
  for skill in catalog.skills:
    if skill.path == skillPath:
      raise newException(SkillsError, skillPath & " is already served")
  for file in files:
    if skillPath & "/" & file.path in catalog.stored:
      raise newException(SkillsError, skillPath & "/" & file.path & " is already served")
  for file in files:
    let mime = if file.path == SkillFileName: "text/markdown"
               elif file.mimeType.len > 0: file.mimeType
               else: mimeTypeOf(file.path)
    catalog.stored[skillPath & "/" & file.path] = StoredFile(
      content: file.content, mimeType: mime, digest: digestOf(file.content))
  catalog.skills.add CatalogSkill(path: skillPath, frontmatter: parsed.fields)

proc addDynamicSkill*(catalog: SkillCatalog, skillPath: string, frontmatter: JsonNode,
                      files: DynamicSkillFiles) =
  ## Serve a skill whose files are generated by `files` on every read. Its
  ## entry says `"dynamic"` instead of a manifest, which offers hosts no
  ## content integrity; some will decline to load it. `frontmatter` is what
  ## the entry carries; the generated SKILL.md must carry the same.
  let name = checkSkillPath(skillPath)
  if frontmatter.isNil or frontmatter.kind != JObject:
    raise newException(SkillsError, skillPath & ": the frontmatter must be an object")
  checkFrontmatter(skillPath, frontmatter, name)
  if files.isNil:
    raise newException(SkillsError, skillPath & ": a dynamic skill needs a file provider")
  for skill in catalog.skills:
    if skill.path == skillPath:
      raise newException(SkillsError, skillPath & " is already served")
  catalog.skills.add CatalogSkill(path: skillPath, frontmatter: frontmatter, files: files)

proc addSkillDirectory*(catalog: SkillCatalog, skillPath, directory: string) =
  ## Serve the skill held in `directory` of the filesystem. Every regular
  ## file below it is served; a symbolic link is refused rather than followed,
  ## since it could lead out of the directory, and so is a directory that is
  ## too large before any of it is read.
  let root = normalizedPath(absolutePath(directory))
  if not dirExists(root):
    raise newException(SkillsError, directory & " is not a directory")
  var files: seq[SkillFile]
  var total = 0'i64
  for path in walkDirRec(root, yieldFilter = {pcFile, pcLinkToFile, pcDir, pcLinkToDir},
                         followFilter = {pcDir}, relative = false):
    let info = getFileInfo(path, followSymlink = false)
    if info.kind in {pcLinkToFile, pcLinkToDir}:
      raise newException(SkillsError, path & " is a symbolic link; skills are served without them")
    if info.kind != pcFile:
      continue
    let normal = normalizedPath(path)
    if not normal.startsWith(root & DirSep):
      raise newException(SkillsError, path & " lies outside " & directory)
    total += info.size
    checkLimits(skillPath, files.len + 1, total)
    files.add SkillFile(path: normal[root.len + 1 .. ^1].replace(DirSep, '/'),
                        content: readFile(normal))
  catalog.addSkill(skillPath, files)

func entryOf(catalog: SkillCatalog, skill: CatalogSkill): JsonNode =
  var entry = SkillEntry(uri: catalog.skillUri(skill), frontmatter: skill.frontmatter,
                         dynamic: not skill.files.isNil)
  if not entry.dynamic:
    let prefix = skill.path & "/"
    # SKILL.md first; nested skills' files are supporting files of this one.
    entry.resources.add SkillResource(
      uri: entry.uri, digest: catalog.stored[prefix & SkillFileName].digest,
      size: catalog.stored[prefix & SkillFileName].content.len)
    for path, file in catalog.stored:
      if path.startsWith(prefix) and path != prefix & SkillFileName:
        entry.resources.add SkillResource(uri: catalog.uriOf(path), digest: file.digest,
                                          size: file.content.len)
  entry.toJson()

type Found = object
  uri: string
  content: string
  mimeType: string

proc generatedFiles(catalog: SkillCatalog): Future[OrderedTable[string, StoredFile]] {.async.} =
  ## The files of every dynamic skill as they are now, by path below the scheme.
  for skill in catalog.skills:
    if skill.files.isNil:
      continue
    for file in await skill.files():
      if not safeFilePath(file.path):
        raise newException(SkillsError, skill.path & ": the provider returned the unsafe path '" &
                                        file.path & "'")
      result[skill.path & "/" & file.path] = StoredFile(
        content: file.content, digest: digestOf(file.content),
        mimeType: if file.mimeType.len > 0: file.mimeType else: mimeTypeOf(file.path))

proc locate(catalog: SkillCatalog, uri: string): Future[Option[Found]] {.async.} =
  let parts = splitResourceUri(uri)
  if parts.isNone or parts.get.scheme != catalog.scheme:
    return none(Found)
  if parts.get.path in catalog.stored:
    let file = catalog.stored[parts.get.path]
    return some(Found(uri: uri, content: file.content, mimeType: file.mimeType))
  for skill in catalog.skills:
    if not skill.files.isNil and parts.get.path.startsWith(skill.path & "/"):
      let generated = await catalog.generatedFiles()
      if parts.get.path in generated:
        let file = generated[parts.get.path]
        return some(Found(uri: uri, content: file.content, mimeType: file.mimeType))
      return none(Found)
  none(Found)

func isText(mimeType, content: string): bool =
  (mimeType.startsWith("text/") or mimeType in ["application/json", "application/yaml"]) and
    validateUtf8(content) == -1

func contentsOf(found: Found): JsonNode =
  result = %*{"uri": found.uri, "mimeType": found.mimeType}
  if isText(found.mimeType, found.content):
    result["text"] = %found.content
  else:
    result["blob"] = %base64.encode(found.content)

func directoryChildren(catalog: SkillCatalog, directory: string,
                       files: OrderedTable[string, StoredFile]): Option[seq[JsonNode]] =
  ## The direct children of `directory` (a path below the scheme), or none
  ## when no file lies below it.
  let prefix = directory & "/"
  var names: seq[string]
  var children: seq[JsonNode]
  var found = false
  for path, file in files:
    if not path.startsWith(prefix):
      continue
    found = true
    let rest = path[prefix.len .. ^1]
    let slash = rest.find('/')
    if slash < 0:
      children.add %*{"uri": catalog.uriOf(path), "name": rest,
                      "mimeType": file.mimeType, "size": file.content.len}
    elif rest[0 ..< slash] notin names:
      names.add rest[0 ..< slash]
      children.add %*{"uri": catalog.uriOf(prefix & rest[0 ..< slash]),
                      "name": rest[0 ..< slash], "mimeType": DirectoryMimeType}
  if found: some(children) else: none(seq[JsonNode])

proc pageOfResult(request: JsonNode, items: seq[JsonNode], pageSize: int, key: string,
                  cache: Option[CachePolicy]): JsonNode =
  let cursor = request{"cursor"}
  if not cursor.isNil and cursor.kind != JString:
    raise newInvalidParams("`cursor` must be a string")
  let page = pageOf(items, (if cursor.isNil: none(string) else: some(cursor.getStr())),
                    pageSize)
  result = newJObject()
  result[key] = %page.items
  if page.nextCursor.isSome:
    result["nextCursor"] = %page.nextCursor.get
  if cache.isSome:
    result["ttlMs"] = %cache.get.ttlMs.int
    result["cacheScope"] = %($cache.get.scope)

proc skillsList(catalog: SkillCatalog, params: JsonNode): JsonNode =
  var entries: seq[JsonNode]
  for skill in catalog.skills:
    entries.add catalog.entryOf(skill)
  pageOfResult(params, entries, catalog.pageSize, "skills", some(catalog.cache))

proc skillsGet(catalog: SkillCatalog, params: JsonNode): JsonNode =
  let uri = params{"uri"}
  if uri.isNil or uri.kind != JString:
    raise newInvalidParams("`uri` must be the URI of a skill's SKILL.md")
  for skill in catalog.skills:
    if catalog.skillUri(skill) == uri.getStr():
      return %*{"skill": catalog.entryOf(skill), "ttlMs": catalog.cache.ttlMs.int,
                "cacheScope": $catalog.cache.scope}
  raise newInvalidParams("No skill is served at " & uri.getStr())

proc directoryRead(catalog: SkillCatalog, params: JsonNode): Future[JsonNode] {.async.} =
  let uri = params{"uri"}
  if uri.isNil or uri.kind != JString:
    raise newInvalidParams("`uri` must be the URI of a directory resource")
  let parts = splitResourceUri(uri.getStr())
  if parts.isNone or parts.get.scheme != catalog.scheme:
    raise newInvalidParams(uri.getStr() & " is not a directory resource")
  var files = catalog.stored
  for path, file in await catalog.generatedFiles():
    files[path] = file
  let children = catalog.directoryChildren(parts.get.path, files)
  if children.isNone:
    raise newInvalidParams(uri.getStr() & " is not a directory resource")
  return pageOfResult(params, children.get, catalog.pageSize, "resources", none(CachePolicy))

proc registerSkills*(server: McpServer, catalog: SkillCatalog, directoryRead = false) =
  ## Declare `io.modelcontextprotocol/skills` on `server` and serve
  ## `catalog`. With `directoryRead` the server also answers
  ## `resources/directory/read` and says so in its settings. The `resources`
  ## capability, which the extension requires, is declared if it is not yet.
  ## Skill files are readable through `resources/read` by every client; the
  ## skills methods answer clients that declared the extension.
  ##
  ## Raises ValueError, naming the extension and its target version, when
  ## the server is limited to a version older than the target
  ## (`officialSkills`; the extension cannot be declared there, and it is not
  ## ignored silently), or when the extension or one of its methods is
  ## already registered.
  requireTargetSpoken(server.protocolVersion, officialSkills)
  if server.capabilities.extensions.isSome and
     server.capabilities.extensions.get.hasKey(SkillsExtensionId):
    raise newException(ValueError, SkillsExtensionId & " is already registered")
  var methods = @[SkillsListMethod, SkillsGetMethod]
  if directoryRead:
    methods.add DirectoryReadMethod
  for methodName in methods:
    if methodName in server.extensionMethods or methodName in server.requestHandlers:
      raise newException(ValueError, "method " & methodName & " is already defined")
  server.registerExtension(SkillsExtensionId,
    (if directoryRead: %*{"directoryRead": true} else: newJObject()))
  if server.capabilities.resources.isNone:
    server.capabilities.resources = some(McpResourcesCapability())
  server.registerExtensionMethod(SkillsExtensionId, SkillsListMethod,
    proc(ctx: McpRequestContext, params: JsonNode): Future[JsonNode] {.async.} =
      return catalog.skillsList(params),
    clientDeclares = false)
  server.registerExtensionMethod(SkillsExtensionId, SkillsGetMethod,
    proc(ctx: McpRequestContext, params: JsonNode): Future[JsonNode] {.async.} =
      return catalog.skillsGet(params),
    clientDeclares = false)
  if directoryRead:
    server.registerExtensionMethod(SkillsExtensionId, DirectoryReadMethod,
      proc(ctx: McpRequestContext, params: JsonNode): Future[JsonNode] {.async.} =
        return await catalog.directoryRead(params),
      clientDeclares = false)
  # A file of a skill is an ordinary resource: `resources/read` answers it
  # here and leaves every other URI to the server's own handler.
  server.addRequestInterceptor(
    proc(ctx: McpRequestContext, request: JsonRpcRequest): Future[Option[JsonRpcResponse]] {.async.} =
      if request.`method` != "resources/read":
        return none(JsonRpcResponse)
      let uri = request.params{"uri"}
      if uri.isNil or uri.kind != JString:
        return none(JsonRpcResponse)
      let found = await catalog.locate(uri.getStr())
      if found.isNone:
        return none(JsonRpcResponse)
      return some(newJsonRpcResponse(request.id, %*{"contents": [contentsOf(found.get)]})))
