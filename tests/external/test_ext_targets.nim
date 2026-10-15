## Every official extension states the protocol version it targets, and its
## registrations agree with that statement on every build: a server or client
## limited to a version below the target refuses each registration, naming
## the extension and the target; at or above it, the extension registers and
## answers a first call.
##
## The loop runs over every version the build speaks, and `testAllVersions`
## runs this file once per released version as the build's default: a build
## whose default is older than an extension's target only ever sees the
## refusal. `registrations` is a `case` over the extensions, so an extension
## added to the table without its registrations here does not compile.
## `enableClientCredentials` and `enableEnterpriseManaged` are not listed:
## they declare through `declareClientCredentials` and
## `declareEnterpriseManaged`, which are.

import std/[asyncdispatch, json, options, strutils, unittest]
import server/server except McpRequestError
import client/client
import client/extensions
import protocol/types
import protocol/version
import ext/tasks
import ext/skills
import ext/auth_client_credentials
import ext/auth_enterprise_managed
import ./ext_skills_fixtures
import ./loopback_transport

type Registration = object
  name: string
  register: proc() {.closure.}

proc serverAt(ceiling: McpProtocolVersion): McpServer =
  newMcpServer(McpServerInfo(name: "test-org/extensions", version: "1"),
               ceiling, McpServerCapabilities(tools: some(McpToolsCapability())))

proc clientAt(ceiling: McpProtocolVersion): McpClient =
  newMcpClient(McpClientInfo(name: "c", version: "1"), ceiling)

proc connect(server: McpServer, client: McpClient) =
  let pair = newLoopbackPair()
  waitFor server.attachTransport(pair.server)
  waitFor client.connect(pair.client)

proc oneSkill(): SkillCatalog =
  result = newSkillCatalog()
  result.addSkill("git-workflow", [SkillFile(path: "SKILL.md", content: GitMd)])

proc registrations(extension: OfficialExtension, ceiling: McpProtocolVersion): seq[Registration] =
  ## Every registration of `extension` a program can make, each on a fresh
  ## server or client limited to `ceiling`.
  case extension
  of officialTasks:
    @[Registration(name: "enableTasksExtension (server)", register: proc() =
        discard serverAt(ceiling).enableTasksExtension()),
      Registration(name: "enableTasksExtension (client)", register: proc() =
        clientAt(ceiling).enableTasksExtension())]
  of officialSkills:
    @[Registration(name: "registerSkills", register: proc() = serverAt(ceiling).registerSkills(oneSkill())),
      Registration(name: "declareSkills", register: proc() = clientAt(ceiling).declareSkills())]
  of officialClientCredentials:
    @[Registration(name: "advertiseClientCredentials", register: proc() =
        serverAt(ceiling).advertiseClientCredentials()),
      Registration(name: "declareClientCredentials", register: proc() =
        clientAt(ceiling).declareClientCredentials())]
  of officialEnterpriseManaged:
    @[Registration(name: "advertiseEnterpriseManaged", register: proc() =
        serverAt(ceiling).advertiseEnterpriseManaged()),
      Registration(name: "declareEnterpriseManaged", register: proc() =
        clientAt(ceiling).declareEnterpriseManaged())]

proc firstCall(extension: OfficialExtension, ceiling: McpProtocolVersion) =
  ## Register both halves of `extension` at `ceiling` and make the first call
  ## a user of it makes.
  let server = serverAt(ceiling)
  let client = clientAt(ceiling)
  case extension
  of officialTasks:
    discard server.enableTasksExtension()
    server.onToolCall(proc(ctx: McpRequestContext, name: string,
                           arguments: JsonNode): Future[JsonNode] {.async.} =
      return %*{"content": [{"type": "text", "text": "done"}]})
    client.enableTasksExtension()
    connect(server, client)
    let started = waitFor client.startToolCall("report")
    check started.task.isNone
    check started.result.isSome
    check started.result.get["content"][0]["text"].getStr() == "done"
  of officialSkills:
    server.registerSkills(oneSkill())
    client.declareSkills()
    connect(server, client)
    check client.skillsOffered()
    let listing = waitFor client.listAllSkills()
    check listing.entries.len == 1
  of officialClientCredentials:
    server.advertiseClientCredentials()
    client.declareClientCredentials()
    connect(server, client)
    check client.serverExtension(ClientCredentialsExtensionId) == some(newJObject())
  of officialEnterpriseManaged:
    server.advertiseEnterpriseManaged()
    client.declareEnterpriseManaged()
    connect(server, client)
    check client.serverExtension(EnterpriseManagedExtensionId) == some(newJObject())

suite "the protocol version each official extension targets":

  test "Given each official extension and each version this build speaks as the ceiling, when every registration of the extension is made below its target, then each is refused naming the extension and the target":
    for extension in OfficialExtension:
      for ceiling in SupportedProtocolVersions:
        if ceiling >= extension.targetVersion:
          continue
        for registration in registrations(extension, ceiling):
          checkpoint $extension & " / " & registration.name & " / " & $ceiling
          var message = ""
          try:
            registration.register()
          except ValueError as e:
            message = e.msg
          check extension.displayName in message
          check $extension.targetVersion in message
          check $ceiling in message

  test "Given each official extension and each version this build speaks as the ceiling, when the extension is registered at or above its target, then every registration is accepted and the first call is answered":
    for extension in OfficialExtension:
      for ceiling in SupportedProtocolVersions:
        if ceiling < extension.targetVersion:
          continue
        for registration in registrations(extension, ceiling):
          checkpoint $extension & " / " & registration.name & " / " & $ceiling
          registration.register()
        checkpoint $extension & " / first call / " & $ceiling
        firstCall(extension, ceiling)
