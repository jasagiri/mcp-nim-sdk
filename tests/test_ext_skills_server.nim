## The server side of the skills extension (ext-skills@167da6c): what a
## server that registered skills tells and serves, and what it refuses to
## register.

import std/[asyncdispatch, base64, json, options, os, strutils, unittest]
import ./server_harness
import ext/skills
import protocol/modern
import ./ext_skills_fixtures

const Ext = SkillsExtensionId

proc skillsDeclared(): JsonNode =
  %*{"io.modelcontextprotocol/clientCapabilities": {"extensions": {Ext: {}}}}

proc pdfFiles(): seq[SkillFile] =
  @[SkillFile(path: "SKILL.md", content: SkillMd),
    SkillFile(path: "templates/invoice.md", content: Invoice),
    SkillFile(path: "templates/purchase-order.md", content: PurchaseOrder)]

proc gitFiles(): seq[SkillFile] =
  @[SkillFile(path: "SKILL.md", content: GitMd)]

proc refundFiles(): seq[SkillFile] =
  @[SkillFile(path: "SKILL.md", content: "---\nname: refunds\ndescription: Process refund requests\nlicense: Apache-2.0\n---\n\nRefund.\n"),
    SkillFile(path: "examples/email.md", content: "Dear customer\n"),
    SkillFile(path: "assets/logo.png", content: "\x89PNG\x00\x01\xff")]

proc standardCatalog(pageSize = 0): SkillCatalog =
  result = newSkillCatalog(cache = CachePolicy(ttlMs: 300000, scope: csPublic),
                           pageSize = pageSize)
  result.addSkill("pdf-processing", pdfFiles())
  result.addSkill("git-workflow", gitFiles())
  result.addSkill("acme/billing/refunds", refundFiles())

proc plainServer(): McpServer =
  result = newServer(McpServerCapabilities())
  result.onResourceRead(proc(ctx: McpRequestContext, uri: string): Future[seq[JsonNode]] {.async.} =
    if uri == "memo://plain":
      return @[%*{"uri": uri, "mimeType": "text/plain", "text": "plain"}]
    raise newResourceNotFound(uri))

proc skillsServer(directoryRead = false, pageSize = 0): McpServer =
  result = plainServer()
  result.registerSkills(standardCatalog(pageSize), directoryRead)

proc uris(entries: JsonNode): seq[string] =
  for entry in entries:
    result.add entry["uri"].getStr()

suite "registering skills on a server":

  test "Given a catalog that was not registered, when a client asks for skills or reads a skill file, then nothing is served":
    for v in versionsWith(ftExtensions):
      let server = plainServer()
      discard standardCatalog()
      let peer = server.connect(server.attach(), v)
      check peer.ask("skills/list", meta = skillsDeclared()).errorCode == -32601
      check peer.ask("skills/get", %*{"uri": "skill://pdf-processing/SKILL.md"},
                     meta = skillsDeclared()).errorCode == -32601
      check peer.ask("resources/read", %*{"uri": "skill://pdf-processing/SKILL.md"}).errorCode == -32601
      check not peer.ask("server/discover")["result"]["capabilities"].hasKey("extensions")

  test "Given a registered catalog, when a 2026-07-28 client discovers the server, then the extension and the resources capability are declared":
    for v in versionsWith(ftExtensions):
      let server = skillsServer()
      let peer = server.connect(server.attach(), v)
      let capabilities = peer.ask("server/discover")["result"]["capabilities"]
      check capabilities["extensions"][Ext] == newJObject()
      check capabilities.hasKey("resources")

  test "Given a server registered with directoryRead, when a client discovers it, then the setting says so":
    for v in versionsWith(ftExtensions):
      let server = skillsServer(directoryRead = true)
      let peer = server.connect(server.attach(), v)
      let capabilities = peer.ask("server/discover")["result"]["capabilities"]
      check capabilities["extensions"][Ext]["directoryRead"].getBool()

  test "Given a registered catalog, when a legacy client initializes, then the capabilities do not mention extensions":
    if isSupported(mpv20260728):
      for v in versionsWithout(ftExtensions):
        let server = skillsServer()
        let t = server.attach()
        discard server.connect(t, v)
        check not t.sent[0].message["result"]["capabilities"].hasKey("extensions")

  test "Given a server that speaks no 2026-07-28, when skills are registered, then ValueError is raised and nothing is declared":
    if isSupported(mpv20251125):
      let server = newMcpServer(McpServerInfo(name: "old", version: "1"),
                                protocolVersion = mpv20251125)
      expect ValueError:
        server.registerSkills(standardCatalog())
      check server.capabilities.extensions.isNone
      check server.capabilities.resources.isNone

  test "Given skills already registered or a method already defined, when they are registered, then ValueError is raised":
    if isSupported(mpv20260728):
      let server = skillsServer()
      expect ValueError:
        server.registerSkills(standardCatalog())
      let other = plainServer()
      other.registerRequestHandler("skills/get", proc(request: JsonRpcRequest): Future[JsonRpcResponse] {.async.} =
        return newJsonRpcResponse(request.id, newJObject()))
      expect ValueError:
        other.registerSkills(standardCatalog())
      check other.capabilities.extensions.isNone

suite "skills/list and skills/get":

  test "Given the skills of the specification's example, when a client lists them, then each entry is a complete manifest with digests":
    for v in versionsWith(ftExtensions):
      let server = skillsServer()
      let peer = server.connect(server.attach(), v)
      let answer = peer.ask("skills/list", meta = skillsDeclared())
      let result = answer["result"]
      check result["resultType"].getStr() == "complete"
      check result["ttlMs"].getInt() == 300000
      check result["cacheScope"].getStr() == "public"
      check result["skills"].uris == @["skill://pdf-processing/SKILL.md",
        "skill://git-workflow/SKILL.md", "skill://acme/billing/refunds/SKILL.md"]
      let pdf = result["skills"][0]
      check pdf == %*{
        "uri": "skill://pdf-processing/SKILL.md",
        "frontmatter": {"name": "pdf-processing",
                        "description": "Extract, fill, and assemble PDF documents"},
        "resources": [
          {"uri": "skill://pdf-processing/SKILL.md",
           "digest": "sha256:99b737495721155ece826d57521e2d66141ebdc1344a400487481ea2642ab19e",
           "size": 151},
          {"uri": "skill://pdf-processing/templates/invoice.md",
           "digest": "sha256:61f4ea6d2c75fde1b4977219e7e3107d491c3c26aefb6686e84d6281c088d9ee",
           "size": 29},
          {"uri": "skill://pdf-processing/templates/purchase-order.md",
           "digest": "sha256:f2ff774b1737ff3dec81c47946f9976f18a1a9f69dda0a81f22eabd95173c158",
           "size": 35}]}
      check result["skills"][2]["frontmatter"]["license"].getStr() == "Apache-2.0"
      check result["skills"][2]["resources"].len == 3

  test "Given a catalog with the default cache policy, when listed, then the result says do not reuse and do not share":
    for v in versionsWith(ftExtensions):
      let server = plainServer()
      let catalog = newSkillCatalog()
      catalog.addSkill("git-workflow", gitFiles())
      server.registerSkills(catalog)
      let peer = server.connect(server.attach(), v)
      let result = peer.ask("skills/list", meta = skillsDeclared())["result"]
      check result["ttlMs"].getInt() == 0
      check result["cacheScope"].getStr() == "private"

  test "Given a catalog of three skills and a page size of two, when a client follows nextCursor, then every skill arrives once":
    for v in versionsWith(ftExtensions):
      let server = skillsServer(pageSize = 2)
      let peer = server.connect(server.attach(), v)
      let first = peer.ask("skills/list", meta = skillsDeclared())["result"]
      check first["skills"].len == 2
      check first.hasKey("nextCursor")
      let second = peer.ask("skills/list", %*{"cursor": first["nextCursor"]},
                            meta = skillsDeclared())["result"]
      check second["skills"].uris == @["skill://acme/billing/refunds/SKILL.md"]
      check not second.hasKey("nextCursor")
      check second["ttlMs"].getInt() == 300000

  test "Given a cursor the server did not issue or one that is not a string, when a client lists skills, then it is invalid params":
    for v in versionsWith(ftExtensions):
      let server = skillsServer(pageSize = 2)
      let peer = server.connect(server.attach(), v)
      check peer.ask("skills/list", %*{"cursor": "bogus"}, meta = skillsDeclared()).errorCode == -32602
      check peer.ask("skills/list", %*{"cursor": 7}, meta = skillsDeclared()).errorCode == -32602

  test "Given a served skill, when skills/get names its SKILL.md, then the entry is returned with cache fields":
    for v in versionsWith(ftExtensions):
      let server = skillsServer()
      let peer = server.connect(server.attach(), v)
      let result = peer.ask("skills/get", %*{"uri": "skill://acme/billing/refunds/SKILL.md"},
                            meta = skillsDeclared())["result"]
      check result["resultType"].getStr() == "complete"
      check result["skill"]["frontmatter"]["name"].getStr() == "refunds"
      check result["skill"]["resources"][0]["uri"].getStr() == "skill://acme/billing/refunds/SKILL.md"
      check result["ttlMs"].getInt() == 300000
      check result["cacheScope"].getStr() == "public"

  test "Given a file of a skill, an unknown URI or no string, when skills/get is called, then each is invalid params":
    for v in versionsWith(ftExtensions):
      let server = skillsServer()
      let peer = server.connect(server.attach(), v)
      for params in [%*{"uri": "skill://pdf-processing/templates/invoice.md"},
                     %*{"uri": "skill://acme/billing/chargebacks/SKILL.md"},
                     %*{"uri": "memo://plain"}, %*{"uri": 5}, newJObject()]:
        checkpoint $params
        check peer.ask("skills/get", params, meta = skillsDeclared()).errorCode == -32602

  test "Given a client that declared nothing, when it asks for skills, then it is served: the specification asks no declaration of the client":
    for v in versionsWith(ftExtensions):
      let server = skillsServer(directoryRead = true)
      let peer = server.connect(server.attach(), v)
      check peer.ask("skills/list", newJObject())["result"]["skills"].len > 0
      check peer.ask("skills/get", %*{"uri": "skill://pdf-processing/SKILL.md"})["result"].kind == JObject
      check peer.ask("resources/directory/read",
                     %*{"uri": "skill://pdf-processing"})["result"].kind == JObject

suite "skill files as resources":

  test "Given a skill with text and binary files, when any client reads them, then text is text and binary is a base64 blob":
    for v in versionsWith(ftExtensions):
      let server = skillsServer()
      let peer = server.connect(server.attach(), v)
      let text = peer.ask("resources/read",
                          %*{"uri": "skill://pdf-processing/templates/invoice.md"})["result"]["contents"][0]
      check text["text"].getStr() == Invoice
      check text["mimeType"].getStr() == "text/markdown"
      check text["uri"].getStr() == "skill://pdf-processing/templates/invoice.md"
      let skillMd = peer.ask("resources/read", %*{"uri": "skill://pdf-processing/SKILL.md"})
      check skillMd["result"]["contents"][0]["text"].getStr() == SkillMd
      let binary = peer.ask("resources/read",
        %*{"uri": "skill://acme/billing/refunds/assets/logo.png"})["result"]["contents"][0]
      check binary["blob"].getStr().decode() == "\x89PNG\x00\x01\xff"
      check binary["mimeType"].getStr() == "image/png"
      check not binary.hasKey("text")

  test "Given a URI that is not a served skill file, when a client reads it, then the server's own handler answers":
    for v in versionsWith(ftExtensions):
      let server = skillsServer()
      let peer = server.connect(server.attach(), v)
      check peer.ask("resources/read", %*{"uri": "memo://plain"})["result"]["contents"][0]["text"].getStr() == "plain"
      check peer.ask("resources/read", %*{"uri": "skill://pdf-processing/missing.md"}).errorCode == -32602
      check peer.ask("resources/read", %*{"uri": "skill://pdf-processing/../x"}).errorCode == -32602
      check peer.ask("resources/read", %*{"uri": "other://pdf-processing/SKILL.md"}).errorCode == -32602

  test "Given a catalog with another scheme, when its files are read, then that scheme is served and skill:// is not":
    for v in versionsWith(ftExtensions):
      let server = plainServer()
      let catalog = newSkillCatalog(scheme = "github")
      catalog.addSkill("owner/repo/skills/git-workflow", gitFiles())
      server.registerSkills(catalog)
      let peer = server.connect(server.attach(), v)
      let uri = "github://owner/repo/skills/git-workflow/SKILL.md"
      check peer.ask("resources/read", %*{"uri": uri})["result"]["contents"][0]["text"].getStr().len > 0
      check peer.ask("skills/get", %*{"uri": uri}, meta = skillsDeclared())["result"]["skill"]["uri"].getStr() == uri
      check peer.ask("resources/read",
        %*{"uri": "skill://owner/repo/skills/git-workflow/SKILL.md"}).errorCode == -32602

suite "reading directories":

  test "Given a server registered with directoryRead, when a client reads a skill root and a subdirectory, then direct children come back":
    for v in versionsWith(ftExtensions):
      let server = skillsServer(directoryRead = true)
      let peer = server.connect(server.attach(), v)
      let root = peer.ask("resources/directory/read", %*{"uri": "skill://pdf-processing"},
                          meta = skillsDeclared())["result"]
      check root["resultType"].getStr() == "complete"
      check root["resources"] == %*[
        {"uri": "skill://pdf-processing/SKILL.md", "name": "SKILL.md",
         "mimeType": "text/markdown", "size": 151},
        {"uri": "skill://pdf-processing/templates", "name": "templates",
         "mimeType": "inode/directory"}]
      let templates = peer.ask("resources/directory/read",
        %*{"uri": "skill://pdf-processing/templates"}, meta = skillsDeclared())["result"]
      check templates["resources"].uris == @["skill://pdf-processing/templates/invoice.md",
                                             "skill://pdf-processing/templates/purchase-order.md"]
      let prefix = peer.ask("resources/directory/read", %*{"uri": "skill://acme"},
                            meta = skillsDeclared())["result"]
      check prefix["resources"][0]["mimeType"].getStr() == "inode/directory"

  test "Given a file, an unknown directory or a missing uri, when a client reads a directory, then each is invalid params":
    for v in versionsWith(ftExtensions):
      let server = skillsServer(directoryRead = true)
      let peer = server.connect(server.attach(), v)
      for params in [%*{"uri": "skill://pdf-processing/SKILL.md"},
                     %*{"uri": "skill://nothing-here"}, %*{"uri": "skill://pdf-processing/../x"},
                     %*{"uri": "memo://plain"}, %*{"uri": 1}, newJObject()]:
        checkpoint $params
        check peer.ask("resources/directory/read", params, meta = skillsDeclared()).errorCode == -32602

  test "Given a server registered without directoryRead, when a client reads a directory, then the method is unknown":
    for v in versionsWith(ftExtensions):
      let server = skillsServer()
      let peer = server.connect(server.attach(), v)
      check peer.ask("resources/directory/read", %*{"uri": "skill://pdf-processing"},
                     meta = skillsDeclared()).errorCode == -32601

  test "Given a directory with more children than a page, when a client follows the cursor, then all arrive":
    for v in versionsWith(ftExtensions):
      let server = plainServer()
      let catalog = newSkillCatalog(pageSize = 2)
      var files = gitFiles()
      for i in 1 .. 3:
        files.add SkillFile(path: "notes/n" & $i & ".md", content: "n")
      catalog.addSkill("git-workflow", files)
      server.registerSkills(catalog, directoryRead = true)
      let peer = server.connect(server.attach(), v)
      let first = peer.ask("resources/directory/read", %*{"uri": "skill://git-workflow/notes"},
                           meta = skillsDeclared())["result"]
      check first["resources"].len == 2
      let second = peer.ask("resources/directory/read",
        %*{"uri": "skill://git-workflow/notes", "cursor": first["nextCursor"]},
        meta = skillsDeclared())["result"]
      check second["resources"].len == 1
      check not second.hasKey("nextCursor")

suite "skills with generated content and nested skills":

  test "Given a skill added with a file provider, when a client lists it and reads its files, then the entry is dynamic and the files are current":
    for v in versionsWith(ftExtensions):
      let server = plainServer()
      let catalog = newSkillCatalog()
      var round = 0
      catalog.addDynamicSkill("reports/daily",
        %*{"name": "daily", "description": "Assemble today's report"},
        proc(): Future[seq[SkillFile]] {.async.} =
          inc round
          return @[SkillFile(path: "SKILL.md",
                             content: "---\nname: daily\ndescription: Assemble today's report\n---\n\nRound " & $round & "\n")])
      server.registerSkills(catalog, directoryRead = true)
      let peer = server.connect(server.attach(), v)
      let listed = peer.ask("skills/list", meta = skillsDeclared())["result"]["skills"][0]
      check listed["resources"].getStr() == "dynamic"
      check listed["frontmatter"]["name"].getStr() == "daily"
      let first = peer.ask("resources/read", %*{"uri": "skill://reports/daily/SKILL.md"})
      let second = peer.ask("resources/read", %*{"uri": "skill://reports/daily/SKILL.md"})
      check first["result"]["contents"][0]["text"].getStr().endsWith("Round 1\n")
      check second["result"]["contents"][0]["text"].getStr().endsWith("Round 2\n")
      check peer.ask("resources/directory/read", %*{"uri": "skill://reports/daily"},
                     meta = skillsDeclared())["result"]["resources"].len == 1

  test "Given skills at acme/billing and acme/billing/refunds, when a client lists them, then the enclosing skill's manifest includes the nested files":
    for v in versionsWith(ftExtensions):
      let server = plainServer()
      let catalog = newSkillCatalog()
      catalog.addSkill("acme/billing", @[SkillFile(path: "SKILL.md",
        content: "---\nname: billing\ndescription: Billing\n---\n\nbilling\n")])
      catalog.addSkill("acme/billing/refunds", refundFiles())
      server.registerSkills(catalog)
      let peer = server.connect(server.attach(), v)
      let skills = peer.ask("skills/list", meta = skillsDeclared())["result"]["skills"]
      check skills[0]["resources"].uris ==
        @["skill://acme/billing/SKILL.md", "skill://acme/billing/refunds/SKILL.md",
          "skill://acme/billing/refunds/examples/email.md",
          "skill://acme/billing/refunds/assets/logo.png"]
      check skills[1]["resources"].len == 3

suite "what a catalog refuses":

  test "Given a skill that cannot be served correctly, when it is added, then SkillsError is raised":
    let catalog = newSkillCatalog()
    let md = "---\nname: pdf-processing\ndescription: d\n---\nbody\n"
    expect SkillsError:  # the frontmatter names another skill
      catalog.addSkill("other-name", @[SkillFile(path: "SKILL.md", content: md)])
    expect SkillsError:  # no SKILL.md
      catalog.addSkill("pdf-processing", @[SkillFile(path: "a.md", content: "x")])
    expect SkillsError:  # unsafe skill path
      catalog.addSkill("../pdf-processing", @[SkillFile(path: "SKILL.md", content: md)])
    expect SkillsError:  # unsafe file path
      catalog.addSkill("pdf-processing", @[SkillFile(path: "SKILL.md", content: md),
                                           SkillFile(path: "../x", content: "x")])
    expect SkillsError:  # absolute file path
      catalog.addSkill("pdf-processing", @[SkillFile(path: "SKILL.md", content: md),
                                           SkillFile(path: "/x", content: "x")])
    expect SkillsError:  # a file given twice
      catalog.addSkill("pdf-processing", @[SkillFile(path: "SKILL.md", content: md),
                                           SkillFile(path: "SKILL.md", content: md)])
    expect SkillsError:  # frontmatter without a description
      catalog.addSkill("pdf-processing", @[SkillFile(path: "SKILL.md",
        content: "---\nname: pdf-processing\n---\nbody\n")])
    expect SkillsError:  # frontmatter outside the supported subset
      catalog.addSkill("pdf-processing", @[SkillFile(path: "SKILL.md",
        content: "---\nname: pdf-processing\ndescription: &x d\n---\nbody\n")])
    expect SkillsError:  # a name that breaks the Agent Skills rules
      catalog.addSkill("PDF", @[SkillFile(path: "SKILL.md",
        content: "---\nname: PDF\ndescription: d\n---\nbody\n")])
    check catalog.pageSize == 0
    catalog.addSkill("pdf-processing", @[SkillFile(path: "SKILL.md", content: md)])
    expect SkillsError:  # the skill twice
      catalog.addSkill("pdf-processing", @[SkillFile(path: "SKILL.md", content: md)])

  test "Given a skill with more than 512 files or more than 16 MiB, when it is added, then SkillsError is raised and the limits themselves are accepted":
    let md = "---\nname: big\ndescription: d\n---\nbody\n"
    let catalog = newSkillCatalog()
    var many = @[SkillFile(path: "SKILL.md", content: md)]
    for i in 1 .. MaxResourcesPerSkill:
      many.add SkillFile(path: "f" & $i, content: "x")
    expect SkillsError:
      catalog.addSkill("big", many)
    many.setLen(MaxResourcesPerSkill)
    catalog.addSkill("big", many)
    let heavy = newSkillCatalog()
    expect SkillsError:
      heavy.addSkill("big", @[SkillFile(path: "SKILL.md", content: md),
        SkillFile(path: "blob.bin", content: 'x'.repeat(int(MaxSkillBytes) - md.len + 1))])
    heavy.addSkill("big", @[SkillFile(path: "SKILL.md", content: md),
      SkillFile(path: "blob.bin", content: 'x'.repeat(int(MaxSkillBytes) - md.len))])

  test "Given a dynamic skill with a frontmatter that does not name it or no provider, when it is added, then SkillsError is raised":
    let catalog = newSkillCatalog()
    let provider = proc(): Future[seq[SkillFile]] {.async.} = return @[]
    expect SkillsError:
      catalog.addDynamicSkill("daily", %*{"name": "weekly", "description": "d"}, provider)
    expect SkillsError:
      catalog.addDynamicSkill("daily", %*{"name": "daily"}, provider)
    expect SkillsError:
      catalog.addDynamicSkill("daily", %*{"name": "daily", "description": "d"}, nil)

  test "Given a scheme that is not one, when a catalog is made, then SkillsError is raised":
    expect SkillsError:
      discard newSkillCatalog(scheme = "")
    expect SkillsError:
      discard newSkillCatalog(scheme = "1x")
    expect SkillsError:
      discard newSkillCatalog(scheme = "a b")

suite "skills kept in a directory":

  let root = getTempDir() / ("mcp-skills-" & $getCurrentProcessId())

  setup:
    removeDir(root)
    createDir(root / "src" / "templates")
    writeFile(root / "src" / "SKILL.md", SkillMd)
    writeFile(root / "src" / "templates" / "invoice.md", Invoice)

  teardown:
    removeDir(root)

  test "Given a directory with SKILL.md and a subdirectory, when it is added, then its files are served with their digests":
    for v in versionsWith(ftExtensions):
      let server = plainServer()
      let catalog = newSkillCatalog()
      catalog.addSkillDirectory("pdf-processing", root / "src")
      server.registerSkills(catalog)
      let peer = server.connect(server.attach(), v)
      let entry = peer.ask("skills/get", %*{"uri": "skill://pdf-processing/SKILL.md"},
                           meta = skillsDeclared())["result"]["skill"]
      check entry["resources"].len == 2
      check entry["resources"][0]["digest"].getStr() == digestOf(SkillMd)
      let read = peer.ask("resources/read", %*{"uri": "skill://pdf-processing/templates/invoice.md"})
      check read["result"]["contents"][0]["text"].getStr() == Invoice

  test "Given a directory holding a symbolic link, when it is added, then SkillsError is raised and nothing is served":
    writeFile(root / "secret.txt", "secret")
    createSymlink(root / "secret.txt", root / "src" / "templates" / "link.md")
    let catalog = newSkillCatalog()
    expect SkillsError:
      catalog.addSkillDirectory("pdf-processing", root / "src")
    check catalog.skillCount == 0

  test "Given a path that is not a directory, when it is added, then SkillsError is raised":
    let catalog = newSkillCatalog()
    expect SkillsError:
      catalog.addSkillDirectory("pdf-processing", root / "missing")
