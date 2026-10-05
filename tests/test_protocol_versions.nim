## Protocol versions as seen through `mcp/protocol`: constants, message
## serialization and the initialize negotiation of `Protocol`.
##
## Expectations are derived from `CURRENT_VERSION`, so the same file passes
## on every `mcp-<version>` release branch.

import std/[unittest, json, options, asyncdispatch]
import ../src/mcp/protocol

proc initialize(p: Protocol, version: JsonNode): ResponseMessage =
  waitFor p.handleRequest(RequestMessage(
    id: "1", methodName: "initialize",
    params: %*{"protocolVersion": version, "capabilities": {}}))

suite "mcp/protocol: version constants":

  test "Given the version constants, when rendered, then each is its release date":
    check $VERSION_20241105 == "2024-11-05"
    check $VERSION_20250326 == "2025-03-26"
    check $VERSION_20250618 == "2025-06-18"
    check $VERSION_20251125 == "2025-11-25"
    check $VERSION_20260728 == "2026-07-28"

  test "Given the version constants, when compared, then they are ordered by release date":
    check VERSION_20241105 < VERSION_20250326
    check VERSION_20250326 < VERSION_20250618
    check VERSION_20250618 < VERSION_20251125
    check VERSION_20251125 < VERSION_20260728

  test "Given CURRENT_VERSION, when compared with the build default, then they are the same":
    check CURRENT_VERSION == DefaultProtocolVersion

  test "Given a release date string, when a version is created from it, then it equals the constant":
    check createVersion("2024-11-05") == VERSION_20241105
    check createVersion("2026-07-28") == VERSION_20260728

  test "Given a string that is not a release date, when a version is created from it, then ValueError is raised":
    expect ValueError:
      discard createVersion("1.0.0")
    expect ValueError:
      discard createVersion("invalid")

suite "mcp/protocol: serialization":

  test "Given an initialize request, when serialized for any version, then protocolVersion is that version's date string":
    for v in McpProtocolVersion:
      let request = RequestMessage(id: "req-1", methodName: "initialize", params: %*{})
      let wire = parseJson(serializeWithVersion(request, v))
      check wire["method"].getStr() == "initialize"
      check wire["params"]["protocolVersion"].kind == JString
      check wire["params"]["protocolVersion"].getStr() == $v

  test "Given the initialized notification, when serialized for any version, then its method name is unchanged":
    for v in McpProtocolVersion:
      let notification = NotificationMessage(
        methodName: "notifications/initialized", params: %*{})
      let wire = parseJson(serializeWithVersion(notification, v))
      check wire["method"].getStr() == "notifications/initialized"
      check parseNotificationWithVersion($wire, v).methodName == "notifications/initialized"

suite "mcp/protocol: Protocol construction":

  test "Given no arguments, when a Protocol is created, then it speaks the build default and every earlier version":
    let p = newProtocol()
    check p.version == CURRENT_VERSION
    check p.supportedVersions == SupportedProtocolVersions

  test "Given a version, when a Protocol is created with it, then it speaks that version and every earlier one":
    let p = newProtocol(VERSION_20241105)
    check p.version == VERSION_20241105
    check p.supportedVersions == @[VERSION_20241105]

  test "Given a version above the build default, when a Protocol is created with it, then ValueError is raised":
    for v in McpProtocolVersion:
      if v > CURRENT_VERSION:
        expect ValueError:
          discard newProtocol(v)

  test "Given a Protocol, when a version outside its supported set is activated, then ValueError is raised":
    let p = newProtocol(VERSION_20241105)
    for v in McpProtocolVersion:
      if v != VERSION_20241105:
        expect ValueError:
          p.activateVersion(v)
    check p.version == VERSION_20241105

suite "mcp/protocol: initialize negotiation":

  test "Given a Protocol, when initialize requests a legacy version it speaks, then the response carries the same version":
    for v in SupportedProtocolVersions:
      if isModern(v): continue
      let p = newProtocol()
      let response = p.initialize(%($v))
      check response.error.isNone
      check response.result.get["protocolVersion"].getStr() == $v
      check p.version == v

  test "Given a Protocol, when initialize requests an unknown version, then the response carries its latest legacy version":
    let p = newProtocol()
    let response = p.initialize(%"2099-01-01")
    let expected = latestLegacyVersion(SupportedProtocolVersions).get
    check response.result.get["protocolVersion"].getStr() == $expected
    check p.version == expected

  test "Given a Protocol limited to 2024-11-05, when initialize requests a newer version, then the response carries 2024-11-05":
    let p = newProtocol(VERSION_20241105)
    let response = p.initialize(%"2025-06-18")
    check response.result.get["protocolVersion"].getStr() == "2024-11-05"

  test "Given a Protocol, when initialize has no protocolVersion, then it answers invalid params":
    let p = newProtocol()
    let response = waitFor p.handleRequest(RequestMessage(
      id: "1", methodName: "initialize", params: %*{"capabilities": {}}))
    check response.result.isNone
    check response.error.get.code == ERR_INVALID_PARAMS

  test "Given a Protocol, when initialize carries a version object, then it answers invalid params":
    let p = newProtocol()
    let response = p.initialize(%*{"major": 1, "minor": 0, "patch": 0})
    check response.error.get.code == ERR_INVALID_PARAMS

  test "Given a registered initialize handler, when initialize is handled, then its result gains the negotiated version":
    let p = newProtocol()
    p.setRequestHandler("initialize", proc(request: RequestMessage): Future[ResponseMessage] {.async, gcsafe.} =
      return createSuccessResponse(request.id, %*{"serverInfo": {"name": "s", "version": "1"}}))
    let response = p.initialize(%"2024-11-05")
    check response.result.get["serverInfo"]["name"].getStr() == "s"
    check response.result.get["protocolVersion"].getStr() == "2024-11-05"
