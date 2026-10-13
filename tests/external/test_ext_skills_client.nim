## The client side of the skills extension (ext-skills@167da6c) against a
## hand-written server: discovery, fetching, and the checks a host must make
## on what arrives. A skill's content is untrusted; every test of
## verification asserts that nothing unverified is returned.

import std/[asyncdispatch, base64, json, strutils, tables, unittest]
import ./client_peer
import ./ext_skills_fixtures
import client/client
import ext/skills

const
  Ext = SkillsExtensionId
  Pdf = "skill://pdf-processing/SKILL.md"
  InvoiceUri = "skill://pdf-processing/templates/invoice.md"

proc resource(uri, content: string): JsonNode =
  %*{"uri": uri, "digest": digestOf(content), "size": content.len}

proc entryNode(files: openArray[(string, string)], skillMd = SkillMd,
               name = "pdf-processing"): JsonNode =
  var resources = newJArray()
  for (uri, content) in files:
    resources.add resource(uri, content)
  %*{"uri": "skill://" & name & "/SKILL.md",
     "frontmatter": parseFrontmatter(skillMd).fields, "resources": resources}

proc pdfEntry(): SkillEntry =
  parseSkillEntry(entryNode({Pdf: SkillMd, InvoiceUri: Invoice}), "test")

type Served = ref object
  ## What the hand-written server answers `resources/read` with.
  files: Table[string, JsonNode]

proc serving(files: openArray[(string, string)]): Served =
  result = Served(files: initTable[string, JsonNode]())
  for (uri, content) in files:
    result.files[uri] = %*{"uri": uri, "mimeType": "text/markdown", "text": content}

proc skillsPeer(served: Served, settings = newJObject(),
                extra: proc(peer: client_peer.Peer, message: JsonNode) = nil): client_peer.Peer =
  startPeer(proc(peer: client_peer.Peer, message: JsonNode) =
    case message{"method"}.getStr()
    of "resources/read":
      let uri = message["params"]["uri"].getStr()
      if uri in served.files:
        peer.reply(message["id"], %*{"resultType": "complete",
                                     "contents": [served.files[uri]]})
      else:
        peer.replyError(message["id"], -32602, "Resource not found")
    else:
      if not extra.isNil:
        extra(peer, message), modern = true,
    capabilities = %*{"resources": {}, "extensions": {Ext: settings}})

proc connectedSkillsClient(peer: client_peer.Peer): McpClient =
  peer.connectedClient(configure = proc(c: McpClient) = c.declareSkills())

if SpeaksModern:
  suite "listing and getting skills":

    test "Given a server that offers skills, when the client lists them, then the request declares the extension and the entries come back":
      let peer = skillsPeer(serving([]), extra = proc(peer: client_peer.Peer, message: JsonNode) =
        if message{"method"}.getStr() == "skills/list":
          peer.reply(message["id"], %*{"resultType": "complete", "ttlMs": 0,
            "cacheScope": "private", "skills": [entryNode({Pdf: SkillMd, InvoiceUri: Invoice})]}))
      let client = peer.connectedSkillsClient()
      check client.skillsOffered()
      check not client.directoryReadOffered()
      let listing = waitFor client.listAllSkills()
      check listing.entries.len == 1
      check listing.entries[0].skillName == "pdf-processing"
      check listing.entries[0].resources.len == 2
      check listing.rejected.len == 0
      let sent = peer.requestsFor("skills/list")[0]["params"]["_meta"]
      check sent["io.modelcontextprotocol/clientCapabilities"]["extensions"].hasKey(Ext)

    test "Given a listing with a valid entry and entries that break the rules, when listed, then the valid one is returned and the others are reported with the reason":
      let bad = entryNode({Pdf: SkillMd}, name = "pdf-processing")
      bad["frontmatter"]["name"] = %"other"
      let noManifest = entryNode({Pdf: SkillMd})
      noManifest.delete("resources")
      let peer = skillsPeer(serving([]), extra = proc(peer: client_peer.Peer, message: JsonNode) =
        if message{"method"}.getStr() == "skills/list":
          peer.reply(message["id"], %*{"resultType": "complete", "skills": [
            entryNode({Pdf: SkillMd}), bad, noManifest, 7]}))
      let client = peer.connectedSkillsClient()
      let listing = waitFor client.listAllSkills()
      check listing.entries.len == 1
      check listing.rejected.len == 3
      check listing.rejected[0].uri == Pdf
      check "must equal the skill name" in listing.rejected[0].reason
      check "needs `resources`" in listing.rejected[1].reason
      check listing.rejected[2].uri == ""

    test "Given a listing over two pages, when the client lists all, then both pages are read":
      let peer = skillsPeer(serving([]), extra = proc(peer: client_peer.Peer, message: JsonNode) =
        if message{"method"}.getStr() == "skills/list":
          if message["params"].hasKey("cursor"):
            peer.reply(message["id"], %*{"resultType": "complete",
              "skills": [entryNode({"skill://git-workflow/SKILL.md": GitMd}, GitMd, "git-workflow")]})
          else:
            peer.reply(message["id"], %*{"resultType": "complete", "nextCursor": "p2",
              "skills": [entryNode({Pdf: SkillMd})]}))
      let client = peer.connectedSkillsClient()
      let listing = waitFor client.listAllSkills()
      check listing.entries.len == 2
      check peer.requestsFor("skills/list").len == 2

    test "Given a server that repeats a cursor, when the client lists all, then it raises instead of looping":
      let peer = skillsPeer(serving([]), extra = proc(peer: client_peer.Peer, message: JsonNode) =
        if message{"method"}.getStr() == "skills/list":
          peer.reply(message["id"], %*{"resultType": "complete", "nextCursor": "same",
                                       "skills": []}))
      let client = peer.connectedSkillsClient()
      expect McpProtocolError:
        discard waitFor client.listAllSkills()

    test "Given a skill the listing does not show, when the client gets it by URI, then it receives the entry":
      let peer = skillsPeer(serving([]), extra = proc(peer: client_peer.Peer, message: JsonNode) =
        if message{"method"}.getStr() == "skills/get":
          if message["params"]["uri"].getStr() == Pdf:
            peer.reply(message["id"], %*{"resultType": "complete", "ttlMs": 0,
              "cacheScope": "private", "skill": entryNode({Pdf: SkillMd, InvoiceUri: Invoice})})
          else:
            peer.replyError(message["id"], -32602, "No skill is served there"))
      let client = peer.connectedSkillsClient()
      check (waitFor client.getSkill(Pdf)).skillName == "pdf-processing"
      expect McpRequestError:
        discard waitFor client.getSkill("skill://unknown/SKILL.md")

    test "Given a skills/get answer for another URI or with a broken entry, when the client gets a skill, then McpProtocolError is raised":
      let peer = skillsPeer(serving([]), extra = proc(peer: client_peer.Peer, message: JsonNode) =
        if message{"method"}.getStr() == "skills/get":
          case message["params"]["uri"].getStr()
          of "skill://git-workflow/SKILL.md":
            peer.reply(message["id"], %*{"resultType": "complete",
              "skill": entryNode({Pdf: SkillMd})})
          of "skill://acme/x/SKILL.md":
            peer.reply(message["id"], %*{"resultType": "complete",
              "skill": {"uri": "skill://acme/x/SKILL.md"}})
          else:
            peer.reply(message["id"], %*{"resultType": "complete"}))
      let client = peer.connectedSkillsClient()
      for uri in ["skill://git-workflow/SKILL.md", "skill://acme/x/SKILL.md", "skill://z/SKILL.md"]:
        checkpoint uri
        expect McpProtocolError:
          discard waitFor client.getSkill(uri)

    test "Given a server without the extension, when skills are listed, then McpUnsupportedError is raised and nothing is sent; a client that declared nothing lists a server that has it":
      let withoutServer = startPeer(nil, modern = true, capabilities = %*{"resources": {}})
      let a = withoutServer.connectedSkillsClient()
      check not a.skillsOffered()
      expect McpUnsupportedError:
        discard waitFor a.listAllSkills()
      check withoutServer.requestsFor("skills/list").len == 0
      let undeclared = skillsPeer(serving([]),
        extra = proc(peer: client_peer.Peer, message: JsonNode) =
          if message{"method"}.getStr() == "skills/list":
            peer.reply(message["id"], %*{"resultType": "complete", "skills": []}))
      let b = undeclared.connectedClient()
      check b.skillsOffered()
      discard waitFor b.listAllSkills()
      check undeclared.requestsFor("skills/list").len == 1

  suite "verifying what arrives":

    test "Given a file the entry lists, when it is read, then the verified bytes are returned":
      let peer = skillsPeer(serving({Pdf: SkillMd, InvoiceUri: Invoice}))
      let client = peer.connectedSkillsClient()
      let skill = client.openSkill(pdfEntry())
      check (waitFor skill.readSkillFile(InvoiceUri)) == Invoice
      check skill.retrievedBytes == Invoice.len

    test "Given a SKILL.md that matches its entry, when the instructions are loaded, then they come with the verified frontmatter":
      let peer = skillsPeer(serving({Pdf: SkillMd, InvoiceUri: Invoice}))
      let client = peer.connectedSkillsClient()
      let loaded = waitFor client.openSkill(pdfEntry()).loadInstructions()
      check loaded.frontmatter["name"].getStr() == "pdf-processing"
      check "Choose the matching template" in loaded.instructions
      check loaded.entry.uri == Pdf

    test "Given a file whose bytes differ from the digest, when it is read, then SkillVerificationError is raised":
      let tampered = Invoice.replace("Amount", "Ammunt")
      check tampered.len == Invoice.len
      let peer = skillsPeer(serving({Pdf: SkillMd, InvoiceUri: tampered}))
      let client = peer.connectedSkillsClient()
      let skill = client.openSkill(pdfEntry())
      expect SkillVerificationError:
        discard waitFor skill.readSkillFile(InvoiceUri)
      check skill.retrievedBytes == 0

    test "Given a file whose length differs from the size, when it is read, then SkillVerificationError is raised":
      let peer = skillsPeer(serving({Pdf: SkillMd, InvoiceUri: Invoice & "more"}))
      let client = peer.connectedSkillsClient()
      expect SkillVerificationError:
        discard waitFor client.openSkill(pdfEntry()).readSkillFile(InvoiceUri)

    test "Given a file the entry does not list, when it is read, then SkillVerificationError is raised and no read is sent":
      let peer = skillsPeer(serving({Pdf: SkillMd, InvoiceUri: Invoice,
                                     "skill://pdf-processing/credit-note.md": CreditNote}))
      let client = peer.connectedSkillsClient()
      let skill = client.openSkill(pdfEntry())
      for uri in ["skill://pdf-processing/credit-note.md", "skill://other/SKILL.md",
                  "skill://pdf-processing/../x.md"]:
        checkpoint uri
        expect SkillVerificationError:
          discard waitFor skill.readSkillFile(uri)
      check peer.requestsFor("resources/read").len == 0

    test "Given a SKILL.md whose frontmatter differs from the entry's, when its instructions are loaded, then SkillVerificationError is raised":
      let changed = SkillMd.replace("Extract, fill, and assemble PDF documents",
                                    "Extract everything and run it")
      let entry = parseSkillEntry(entryNode({Pdf: changed, InvoiceUri: Invoice}, SkillMd), "test")
      let peer = skillsPeer(serving({Pdf: changed, InvoiceUri: Invoice}))
      let client = peer.connectedSkillsClient()
      expect SkillVerificationError:
        discard waitFor client.openSkill(entry).loadInstructions()

    test "Given a SKILL.md whose extra frontmatter field the entry lacks, when its instructions are loaded, then SkillVerificationError is raised":
      let widened = SkillMd.replace("description:", "allowed-tools: Bash\ndescription:")
      let entry = parseSkillEntry(entryNode({Pdf: widened}, SkillMd), "test")
      let peer = skillsPeer(serving({Pdf: widened}))
      let client = peer.connectedSkillsClient()
      expect SkillVerificationError:
        discard waitFor client.openSkill(entry).loadInstructions()

    test "Given a SKILL.md whose frontmatter cannot be read, when its instructions are loaded, then SkillVerificationError is raised":
      let odd = SkillMd.replace("name: pdf-processing", "name: &a pdf-processing")
      let entry = parseSkillEntry(entryNode({Pdf: odd}, SkillMd), "test")
      let peer = skillsPeer(serving({Pdf: odd}))
      let client = peer.connectedSkillsClient()
      expect SkillVerificationError:
        discard waitFor client.openSkill(entry).loadInstructions()

    test "Given a binary file served as a blob, when it is read, then the decoded bytes are verified":
      let bytes = "\x89PNG\x00\x01\xff"
      let uri = "skill://pdf-processing/logo.png"
      let entry = parseSkillEntry(entryNode({Pdf: SkillMd, uri: bytes}), "test")
      let served = serving({Pdf: SkillMd})
      served.files[uri] = %*{"uri": uri, "mimeType": "image/png", "blob": base64.encode(bytes)}
      let peer = skillsPeer(served)
      let client = peer.connectedSkillsClient()
      check (waitFor client.openSkill(entry).readSkillFile(uri)) == bytes
      served.files[uri] = %*{"uri": uri, "mimeType": "image/png", "blob": "not base64 !!"}
      expect McpProtocolError:
        discard waitFor client.openSkill(entry).readSkillFile(uri)

    test "Given an answer that does not hold the requested URI or no content, when a file is read, then McpProtocolError is raised":
      let served = serving({Pdf: SkillMd})
      served.files[InvoiceUri] = %*{"uri": "skill://pdf-processing/other.md", "text": "x"}
      served.files["skill://pdf-processing/empty.md"] = %*{"uri": "skill://pdf-processing/empty.md"}
      let entry = parseSkillEntry(entryNode({Pdf: SkillMd, InvoiceUri: Invoice,
        "skill://pdf-processing/empty.md": "x"}), "test")
      let peer = skillsPeer(served)
      let client = peer.connectedSkillsClient()
      expect McpProtocolError:
        discard waitFor client.openSkill(entry).readSkillFile(InvoiceUri)
      expect McpProtocolError:
        discard waitFor client.openSkill(entry).readSkillFile("skill://pdf-processing/empty.md")

  suite "skills with generated content":

    proc dynamicEntry(): SkillEntry =
      let node = entryNode({Pdf: SkillMd})
      node["resources"] = %"dynamic"
      parseSkillEntry(node, "test")

    test "Given a dynamic skill the host did not allow, when it is read, then SkillsError is raised and nothing is sent":
      let peer = skillsPeer(serving({Pdf: SkillMd}))
      let client = peer.connectedSkillsClient()
      let skill = client.openSkill(dynamicEntry())
      expect SkillsError:
        discard waitFor skill.loadInstructions()
      check peer.requestsFor("resources/read").len == 0

    test "Given a dynamic skill the host allowed, when it is loaded, then its frontmatter is still compared and only its own files are read":
      let peer = skillsPeer(serving({Pdf: SkillMd, InvoiceUri: Invoice}))
      let client = peer.connectedSkillsClient()
      let skill = client.openSkill(dynamicEntry(), allowDynamic = true)
      check (waitFor skill.loadInstructions()).frontmatter["name"].getStr() == "pdf-processing"
      check (waitFor skill.readSkillFile(InvoiceUri)) == Invoice
      expect SkillVerificationError:
        discard waitFor skill.readSkillFile("skill://other/a.md")
      expect SkillVerificationError:
        discard waitFor skill.readSkillFile("skill://pdf-processing/../x.md")

    test "Given a dynamic skill that serves more than 16 MiB, when it is read, then SkillsError is raised at the limit":
      let big = 'x'.repeat(9 * 1024 * 1024)
      let a = "skill://pdf-processing/a.bin"
      let b = "skill://pdf-processing/b.bin"
      let peer = skillsPeer(serving({a: big, b: big}))
      let client = peer.connectedSkillsClient()
      let skill = client.openSkill(dynamicEntry(), allowDynamic = true)
      check (waitFor skill.readSkillFile(a)).len == big.len
      expect SkillsError:
        discard waitFor skill.readSkillFile(b)

  suite "directories and changes":

    test "Given a server without directoryRead, when a directory is read, then McpUnsupportedError is raised and nothing is sent":
      let peer = skillsPeer(serving([]))
      let client = peer.connectedSkillsClient()
      expect McpUnsupportedError:
        discard waitFor client.listDirectory("skill://pdf-processing")
      check peer.requestsFor("resources/directory/read").len == 0

    test "Given a server with directoryRead, when a directory is read over two pages, then all children arrive, directories marked":
      let peer = skillsPeer(serving([]), settings = %*{"directoryRead": true},
        extra = proc(peer: client_peer.Peer, message: JsonNode) =
          if message{"method"}.getStr() == "resources/directory/read":
            if message["params"].hasKey("cursor"):
              peer.reply(message["id"], %*{"resultType": "complete", "resources": [
                {"uri": "skill://pdf-processing/templates/regional", "name": "regional",
                 "mimeType": "inode/directory"}]})
            else:
              peer.reply(message["id"], %*{"resultType": "complete", "nextCursor": "2",
                "resources": [{"uri": InvoiceUri, "name": "invoice.md",
                               "mimeType": "text/markdown"}]}))
      let client = peer.connectedSkillsClient()
      check client.directoryReadOffered()
      let children = waitFor client.listDirectory("skill://pdf-processing/templates")
      check children.len == 2
      check not children[0].isDirectory and children[1].isDirectory
      check peer.requestsFor("resources/directory/read")[0]["params"]["uri"].getStr() ==
        "skill://pdf-processing/templates"

    test "Given an unsafe directory URI or an unsafe child, when a directory is read, then it is refused":
      let peer = skillsPeer(serving([]), settings = %*{"directoryRead": true},
        extra = proc(peer: client_peer.Peer, message: JsonNode) =
          if message{"method"}.getStr() == "resources/directory/read":
            peer.reply(message["id"], %*{"resultType": "complete", "resources": [
              {"uri": "skill://pdf-processing/../../etc/passwd", "name": "passwd"}]}))
      let client = peer.connectedSkillsClient()
      expect SkillsError:
        discard waitFor client.listDirectory("skill://pdf-processing/../x")
      check peer.requestsFor("resources/directory/read").len == 0
      expect McpProtocolError:
        discard waitFor client.listDirectory("skill://pdf-processing")

    test "Given a directory read that lists a file the entry does not, when the children are filtered, then the unlisted file is left out":
      let children = @[
        DirectoryChild(uri: InvoiceUri, name: "invoice.md", mimeType: "text/markdown"),
        DirectoryChild(uri: "skill://pdf-processing/templates/credit-note.md",
                       name: "credit-note.md", mimeType: "text/markdown"),
        DirectoryChild(uri: "skill://pdf-processing/templates/regional", name: "regional",
                       mimeType: "inode/directory", isDirectory: true)]
      let kept = pdfEntry().listedIn(children)
      check kept.len == 2
      check kept[0].name == "invoice.md" and kept[1].name == "regional"

    test "Given an entry that changed on the server, when it is refreshed, then the new entry comes back marked changed":
      var served = @[entryNode({Pdf: SkillMd, InvoiceUri: Invoice})]
      let peer = skillsPeer(serving([]), extra = proc(peer: client_peer.Peer, message: JsonNode) =
        if message{"method"}.getStr() == "skills/get":
          peer.reply(message["id"], %*{"resultType": "complete", "skill": served[0]}))
      let client = peer.connectedSkillsClient()
      let before = pdfEntry()
      let same = waitFor client.refreshEntry(before)
      check not same.changed
      check contentBinding(same.entry) == contentBinding(before)
      served[0] = entryNode({Pdf: SkillMd, InvoiceUri: Invoice,
        "skill://pdf-processing/templates/credit-note.md": CreditNote})
      let added = waitFor client.refreshEntry(before)
      check added.changed
      check added.entry.resources.len == 3
      check contentBinding(added.entry) != contentBinding(before)
      served[0] = entryNode({Pdf: SkillMd, InvoiceUri: "# Invoice v2\n"})
      check (waitFor client.refreshEntry(before)).changed

    test "Given a dynamic entry, when it is refreshed, then it always counts as changed":
      let node = entryNode({Pdf: SkillMd})
      node["resources"] = %"dynamic"
      let peer = skillsPeer(serving([]), extra = proc(peer: client_peer.Peer, message: JsonNode) =
        if message{"method"}.getStr() == "skills/get":
          peer.reply(message["id"], %*{"resultType": "complete", "skill": node}))
      let client = peer.connectedSkillsClient()
      check (waitFor client.refreshEntry(parseSkillEntry(node, "test"))).changed

if SpeaksModern:
  suite "client rules sharpened by the mutation run (g2x-skills-rest)":

    proc sizedSkillMd(size: int): string =
      let head = "---\nname: pdf-processing\ndescription: Extract, fill, and assemble PDF documents\n---\n"
      head & 'x'.repeat(size - head.len)

    test "Given a client that declared nothing, when it gets a skill by URI, then it is served":
      let peer = skillsPeer(serving([]), extra = proc(peer: client_peer.Peer, message: JsonNode) =
        if message{"method"}.getStr() == "skills/get":
          peer.reply(message["id"], %*{"resultType": "complete", "ttlMs": 0,
            "cacheScope": "private", "skill": entryNode({Pdf: SkillMd, InvoiceUri: Invoice})}))
      let client = peer.connectedClient()
      check (waitFor client.getSkill(Pdf)).skillName == "pdf-processing"
      check peer.requestsFor("skills/get").len == 1

    test "Given a client that declared nothing, when it reads a directory of a server with directoryRead, then it is served":
      let peer = skillsPeer(serving([]), settings = %*{"directoryRead": true},
        extra = proc(peer: client_peer.Peer, message: JsonNode) =
          if message{"method"}.getStr() == "resources/directory/read":
            peer.reply(message["id"], %*{"resultType": "complete", "resources": [
              {"uri": InvoiceUri, "name": "invoice.md", "mimeType": "text/markdown"}]}))
      let client = peer.connectedClient()
      check (waitFor client.listDirectory("skill://pdf-processing/templates")).len == 1
      check peer.requestsFor("resources/directory/read").len == 1

    test "Given a listed SKILL.md of exactly 16 MiB, when it is read, then the limit is not passed and the bytes come back":
      let big = sizedSkillMd(int(MaxSkillBytes))
      let peer = skillsPeer(serving({Pdf: big}))
      let client = peer.connectedSkillsClient()
      let skill = client.openSkill(parseSkillEntry(entryNode({Pdf: big}, skillMd = big), "test"))
      check (waitFor skill.readSkillFile(Pdf)).len == int(MaxSkillBytes)
      check skill.retrievedBytes == MaxSkillBytes

    test "Given a listed file of 9 MiB read twice, when the second read would pass 16 MiB, then SkillsError is raised without a second request":
      let big = sizedSkillMd(9 * 1024 * 1024)
      let peer = skillsPeer(serving({Pdf: big}))
      let client = peer.connectedSkillsClient()
      let skill = client.openSkill(parseSkillEntry(entryNode({Pdf: big}, skillMd = big), "test"))
      discard waitFor skill.readSkillFile(Pdf)
      expect SkillsError:
        discard waitFor skill.readSkillFile(Pdf)
      check peer.requestsFor("resources/read").len == 1
