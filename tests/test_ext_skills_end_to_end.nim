## The SDK's skills server and skills client over one in-process transport:
## the two halves must agree on the wire, not only each with a hand-written
## peer. The server serves the specification's example skill.

import std/[asyncdispatch, json, options, strutils, unittest]
import server/server except McpRequestError
import client/client
import ext/skills
import protocol/types
import protocol/modern
import ./ext_skills_fixtures
import ./loopback_transport

proc skillsServer(directoryRead: bool): McpServer =
  let server = newMcpServer(McpServerInfo(name: "docs-server", version: "1"))
  let catalog = newSkillCatalog(cache = CachePolicy(ttlMs: 1000, scope: csPublic))
  catalog.addSkill("pdf-processing", @[
    SkillFile(path: "SKILL.md", content: SkillMd),
    SkillFile(path: "templates/invoice.md", content: Invoice),
    SkillFile(path: "templates/purchase-order.md", content: PurchaseOrder)])
  server.registerSkills(catalog, directoryRead)
  server

proc connected(server: McpServer, declare: bool): McpClient =
  let pair = newLoopbackPair()
  waitFor server.attachTransport(pair.server)
  let client = newMcpClient(McpClientInfo(name: "host", version: "1"))
  if declare:
    client.declareSkills()
  waitFor client.connect(pair.client)
  client

if isSupported(mpv20260728):
  suite "skills end to end":

    test "Given a server that registered skills, when a client lists, gets and loads a skill, then the served instructions arrive verified":
      let client = skillsServer(directoryRead = false).connected(declare = true)
      check client.negotiatedVersion == some(mpv20260728)
      check client.skillsOffered()
      let listing = waitFor client.listAllSkills()
      check listing.rejected.len == 0
      check listing.entries.len == 1
      let entry = waitFor client.getSkill(listing.entries[0].uri)
      check contentBinding(entry) == contentBinding(listing.entries[0])
      let skill = client.openSkill(entry)
      let loaded = waitFor skill.loadInstructions()
      check loaded.frontmatter["name"].getStr() == "pdf-processing"
      check "Choose the matching template" in loaded.instructions
      check (waitFor skill.readSkillFile("skill://pdf-processing/templates/purchase-order.md")) == PurchaseOrder
      check skill.retrievedBytes == SkillMd.len + PurchaseOrder.len

    test "Given a server with directoryRead, when a client lists a directory, then the manifest and the directory agree":
      let client = skillsServer(directoryRead = true).connected(declare = true)
      check client.directoryReadOffered()
      let entry = (waitFor client.listAllSkills()).entries[0]
      let children = waitFor client.listDirectory("skill://pdf-processing/templates")
      check children.len == 2
      check entry.listedIn(children).len == 2

    test "Given a server without directoryRead, when a client lists a directory, then it refuses before sending":
      let client = skillsServer(directoryRead = false).connected(declare = true)
      expect McpUnsupportedError:
        discard waitFor client.listDirectory("skill://pdf-processing/templates")

    test "Given a client that did not declare the extension, when it lists skills, then it raises before sending":
      let client = skillsServer(directoryRead = false).connected(declare = false)
      expect McpUnsupportedError:
        discard waitFor client.listAllSkills()
