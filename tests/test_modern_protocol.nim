## Request rules of protocol version 2026-07-28: per-request metadata,
## results, discovery and the Streamable HTTP headers that mirror the body.
##
## Expected message shapes follow the examples published with the
## specification (schema/2026-07-28/examples).

import std/[unittest, json, options, strutils]
import protocol/types
import protocol/modern

const All = [mpv20241105, mpv20250326, mpv20250618, mpv20251125, mpv20260728]
const LegacyOnly = [mpv20241105, mpv20250326, mpv20250618, mpv20251125]

proc modernParams(extra: JsonNode = newJObject()): JsonNode =
  result = %*{"_meta": {
    "io.modelcontextprotocol/protocolVersion": "2026-07-28",
    "io.modelcontextprotocol/clientInfo": {"name": "ExampleClient", "version": "1.0.0"},
    "io.modelcontextprotocol/clientCapabilities": {}}}
  for key, value in extra.pairs:
    result[key] = value

proc server(): McpServerInfo = McpServerInfo(name: "ExampleServer", version: "1.0.0")

suite "2026-07-28: telling modern requests from legacy ones":

  test "Given params whose _meta names a protocol version, when classified, then the request is modern":
    check isModernRequest(modernParams())

  test "Given params whose _meta carries only a progress token, when classified, then the request is legacy":
    check not isModernRequest(%*{"_meta": {"progressToken": "abc"}})

  test "Given params without _meta, null params or non-object params, when classified, then the request is legacy":
    check not isModernRequest(%*{"name": "x"})
    check not isModernRequest(nil)
    check not isModernRequest(newJNull())
    check not isModernRequest(%*[1, 2])
    check not isModernRequest(%*{"_meta": "text"})

suite "2026-07-28: validating request metadata":

  test "Given the specification's example request, when validated, then it is accepted":
    check validateModernRequest(modernParams(), All).isNone

  test "Given a request without clientInfo, when validated, then it is accepted":
    let params = modernParams()
    params["_meta"].delete("io.modelcontextprotocol/clientInfo")
    check validateModernRequest(params, All).isNone

  test "Given a request without clientCapabilities, when validated, then it is rejected as invalid params":
    let params = modernParams()
    params["_meta"].delete("io.modelcontextprotocol/clientCapabilities")
    let rejection = validateModernRequest(params, All)
    check rejection.get.code == -32602
    check "clientCapabilities" in rejection.get.message

  test "Given clientCapabilities that is not an object, when validated, then it is rejected as invalid params":
    let params = modernParams()
    params["_meta"]["io.modelcontextprotocol/clientCapabilities"] = newJNull()
    check validateModernRequest(params, All).get.code == -32602

  test "Given clientInfo that is not an object, when validated, then it is rejected as invalid params":
    let params = modernParams()
    params["_meta"]["io.modelcontextprotocol/clientInfo"] = %"ExampleClient"
    check validateModernRequest(params, All).get.code == -32602

  test "Given a protocol version that is not a string, when validated, then it is rejected as invalid params":
    let params = modernParams()
    params["_meta"]["io.modelcontextprotocol/protocolVersion"] = %20260728
    check validateModernRequest(params, All).get.code == -32602

  test "Given params without _meta, when validated, then it is rejected as invalid params":
    check validateModernRequest(%*{"name": "x"}, All).get.code == -32602
    check validateModernRequest(nil, All).get.code == -32602

  test "Given an unknown protocol version, when validated, then the error lists supported versions newest first and echoes the request":
    let params = modernParams()
    params["_meta"]["io.modelcontextprotocol/protocolVersion"] = %"1900-01-01"
    let rejection = validateModernRequest(params, All).get
    check rejection.code == -32022
    check rejection.message == "Unsupported protocol version"
    check rejection.data == %*{
      "supported": ["2026-07-28", "2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"],
      "requested": "1900-01-01"}

  test "Given a server that speaks only legacy versions, when a 2026-07-28 request is validated, then it is rejected as unsupported":
    let rejection = validateModernRequest(modernParams(), LegacyOnly).get
    check rejection.code == -32022
    check rejection.data["requested"].getStr() == "2026-07-28"
    check rejection.data["supported"][0].getStr() == "2025-11-25"

  test "Given a legacy version named in _meta, when validated, then it is rejected as unsupported":
    let params = modernParams()
    params["_meta"]["io.modelcontextprotocol/protocolVersion"] = %"2025-11-25"
    check validateModernRequest(params, All).get.code == -32022

  test "Given an unsupported version and missing capabilities, when validated, then the version error wins":
    let params = %*{"_meta": {"io.modelcontextprotocol/protocolVersion": "1900-01-01"}}
    check validateModernRequest(params, All).get.code == -32022

suite "2026-07-28: methods":

  test "Given the methods the version removed, when checked, then each is reported removed":
    for name in ["initialize", "ping", "logging/setLevel", "resources/subscribe",
                 "resources/unsubscribe", "tasks/get", "tasks/result",
                 "tasks/cancel", "tasks/list"]:
      check isRemovedInModern(name)

  test "Given methods the version keeps or adds, when checked, then none is reported removed":
    for name in ["server/discover", "tools/list", "tools/call", "prompts/list",
                 "prompts/get", "resources/list", "resources/read",
                 "resources/templates/list", "completion/complete",
                 "subscriptions/listen"]:
      check not isRemovedInModern(name)

  test "Given each method, when asked whether its result is cacheable, then exactly the six cacheable ones are":
    for name in ["server/discover", "tools/list", "prompts/list", "resources/list",
                 "resources/templates/list", "resources/read"]:
      check isCacheable(name)
    for name in ["tools/call", "prompts/get", "completion/complete", "subscriptions/listen"]:
      check not isCacheable(name)

suite "2026-07-28: results":

  test "Given a tools/call result, when completed, then it gains resultType and the server identity but no cache fields":
    let completed = completeResult("tools/call",
      %*{"content": [{"type": "text", "text": "72F"}], "isError": false}, server())
    check completed["resultType"].getStr() == "complete"
    check completed["content"][0]["text"].getStr() == "72F"
    check completed["isError"].getBool() == false
    check completed["_meta"]["io.modelcontextprotocol/serverInfo"] ==
      %*{"name": "ExampleServer", "version": "1.0.0"}
    check not completed.hasKey("ttlMs")
    check not completed.hasKey("cacheScope")

  test "Given a tools/list result and a cache policy, when completed, then it carries that policy":
    let completed = completeResult("tools/list", %*{"tools": []}, server(),
      CachePolicy(ttlMs: 3600000, scope: csPublic))
    check completed["ttlMs"].getInt() == 3600000
    check completed["cacheScope"].getStr() == "public"
    check completed["resultType"].getStr() == "complete"

  test "Given a cacheable result and no policy, when completed, then it is marked not reusable and private":
    for name in ["server/discover", "tools/list", "prompts/list", "resources/list",
                 "resources/templates/list", "resources/read"]:
      let completed = completeResult(name, newJObject(), server())
      check completed["ttlMs"].getInt() == 0
      check completed["cacheScope"].getStr() == "private"

  test "Given a result whose handler already set cache fields, when completed, then the handler's values are kept":
    let completed = completeResult("resources/read",
      %*{"contents": [], "ttlMs": 5, "cacheScope": "public"}, server(),
      CachePolicy(ttlMs: 99, scope: csPrivate))
    check completed["ttlMs"].getInt() == 5
    check completed["cacheScope"].getStr() == "public"

  test "Given an input_required result of a cacheable method, when completed, then it gains no cache fields":
    let completed = completeResult("resources/read",
      %*{"resultType": "input_required", "requestState": "s"}, server(),
      CachePolicy(ttlMs: 10, scope: csPublic))
    check completed["resultType"].getStr() == "input_required"
    check not completed.hasKey("ttlMs")
    check not completed.hasKey("cacheScope")

  test "Given a result with its own _meta, when completed, then the existing keys are kept":
    let completed = completeResult("tools/call",
      %*{"content": [], "_meta": {"traceparent": "00-abc"}}, server())
    check completed["_meta"]["traceparent"].getStr() == "00-abc"
    check completed["_meta"].hasKey("io.modelcontextprotocol/serverInfo")

  test "Given a result that already names a server identity, when completed, then that identity is kept":
    let completed = completeResult("tools/call",
      %*{"content": [], "_meta": {"io.modelcontextprotocol/serverInfo":
        {"name": "Upstream", "version": "9"}}}, server())
    check completed["_meta"]["io.modelcontextprotocol/serverInfo"]["name"].getStr() == "Upstream"

  test "Given a handler's result object, when completed, then the original object is not modified":
    let payload = %*{"tools": []}
    discard completeResult("tools/list", payload, server())
    check payload == %*{"tools": []}

  test "Given results with each resultType, when classified, then absent means complete and unknown values are unknown":
    check resultKind(%*{"tools": []}) == rkComplete
    check resultKind(%*{"resultType": "complete"}) == rkComplete
    check resultKind(%*{"resultType": "input_required"}) == rkInputRequired
    check resultKind(%*{"resultType": "task"}) == rkUnknown
    check resultKind(%*{"resultType": 1}) == rkUnknown

suite "2026-07-28: discovery":

  test "Given a server's versions and capabilities, when the discover result is built, then it matches the specification's example":
    let completed = completeResult("server/discover",
      discoverPayload([mpv20260728], %*{"tools": {}, "resources": {}}),
      server(), CachePolicy(ttlMs: 3600000, scope: csPublic))
    check completed == %*{
      "resultType": "complete",
      "supportedVersions": ["2026-07-28"],
      "capabilities": {"tools": {}, "resources": {}},
      "_meta": {"io.modelcontextprotocol/serverInfo":
        {"name": "ExampleServer", "version": "1.0.0"}},
      "ttlMs": 3600000,
      "cacheScope": "public"}

  test "Given a server that also speaks legacy versions, when the discover result is built, then versions are listed newest first":
    let payload = discoverPayload(All, newJObject())
    check payload["supportedVersions"] ==
      %*["2026-07-28", "2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

  test "Given instructions, when the discover result is built, then it carries them, and omits the field when there are none":
    check discoverPayload(All, newJObject(), "Use wisely.")["instructions"].getStr() == "Use wisely."
    check not discoverPayload(All, newJObject()).hasKey("instructions")

suite "2026-07-28: request metadata a client sends":

  test "Given a client's identity and capabilities, when request metadata is built, then it matches the specification's example":
    let meta = requestMeta(mpv20260728,
      McpClientInfo(name: "ExampleClient", version: "1.0.0"), newJObject())
    check meta == modernParams()["_meta"]

  test "Given params with a progress token, when metadata is attached, then the token is kept beside the protocol fields":
    let meta = requestMeta(mpv20260728, McpClientInfo(name: "c", version: "1"), newJObject())
    let params = withRequestMeta(%*{"name": "get_weather", "_meta": {"progressToken": "t1"}}, meta)
    check params["name"].getStr() == "get_weather"
    check params["_meta"]["progressToken"].getStr() == "t1"
    check params["_meta"]["io.modelcontextprotocol/protocolVersion"].getStr() == "2026-07-28"

  test "Given no params, when metadata is attached, then params is an object holding only _meta":
    let meta = requestMeta(mpv20260728, McpClientInfo(name: "c", version: "1"), newJObject())
    check withRequestMeta(nil, meta) == %*{"_meta": meta}

  test "Given a caller's params, when metadata is attached, then the caller's object is not modified":
    let original = %*{"name": "x"}
    let meta = requestMeta(mpv20260728, McpClientInfo(name: "c", version: "1"), newJObject())
    discard withRequestMeta(original, meta)
    check original == %*{"name": "x"}

suite "2026-07-28: header value encoding":

  test "Given the specification's encoding examples, when encoded, then each matches":
    check encodeHeaderValue("us-west1") == "us-west1"
    check encodeHeaderValue("Hello, 世界") == "=?base64?SGVsbG8sIOS4lueVjA==?="
    check encodeHeaderValue(" padded ") == "=?base64?IHBhZGRlZCA=?="
    check encodeHeaderValue("line1\nline2") == "=?base64?bGluZTEKbGluZTI=?="
    check encodeHeaderValue("=?base64?literal?=") == "=?base64?PT9iYXNlNjQ/bGl0ZXJhbD89?="

  test "Given values with inner spaces, a trailing tab or a control character, when encoded, then only the unsafe ones are Base64":
    check encodeHeaderValue("New York") == "New York"
    check encodeHeaderValue("a\tb") == "a\tb"
    check encodeHeaderValue("tab\t").startsWith("=?base64?")
    check encodeHeaderValue("bell\x07").startsWith("=?base64?")
    check encodeHeaderValue("del\x7F").startsWith("=?base64?")

  test "Given any encoded value, when decoded, then the original is recovered":
    for value in ["us-west1", "Hello, 世界", " padded ", "line1\nline2",
                  "=?base64?literal?=", "file:///projects/myapp/config.json", ""]:
      check decodeHeaderValue(encodeHeaderValue(value)) == some(value)

  test "Given a sentinel whose payload is not Base64, when decoded, then the header is malformed":
    check decodeHeaderValue("=?base64?***?=").isNone

  test "Given a sentinel whose Base64 payload lacks its padding or has too much, when decoded, then the header is malformed":
    check decodeHeaderValue("=?base64?SGVsbG8=?=") == some("Hello")
    check decodeHeaderValue("=?base64?SGVsbG8?=").isNone
    check decodeHeaderValue("=?base64?SGVsbG8===?=").isNone
    check decodeHeaderValue("=?base64?SG=sbG8=?=").isNone

  test "Given a plain value with a raw control or non-ASCII character, when decoded, then the header is malformed":
    check decodeHeaderValue("line1\nline2").isNone
    check decodeHeaderValue("世界").isNone
    check decodeHeaderValue(" padded").isNone

suite "2026-07-28: Streamable HTTP request headers":

  test "Given a tools/call request, when headers are built, then they match the specification's example":
    let params = modernParams(%*{"name": "get_weather", "arguments": {"location": "Seattle, WA"}})
    check modernRequestHeaders("tools/call", params) == @[
      ("MCP-Protocol-Version", "2026-07-28"),
      ("Mcp-Method", "tools/call"),
      ("Mcp-Name", "get_weather")]

  test "Given a resources/read request, when headers are built, then Mcp-Name is the URI":
    let params = modernParams(%*{"uri": "file:///projects/myapp/config.json"})
    check modernRequestHeaders("resources/read", params)[2] ==
      ("Mcp-Name", "file:///projects/myapp/config.json")

  test "Given a prompts/get request with a non-ASCII name, when headers are built, then Mcp-Name is Base64":
    let params = modernParams(%*{"name": "挨拶"})
    check modernRequestHeaders("prompts/get", params)[2][1].startsWith("=?base64?")

  test "Given a tools/list request, when headers are built, then there is no Mcp-Name":
    check modernRequestHeaders("tools/list", modernParams()) == @[
      ("MCP-Protocol-Version", "2026-07-28"), ("Mcp-Method", "tools/list")]

  test "Given headers built from a request, when checked against that request, then they agree":
    for (name, extra) in [("tools/list", newJObject()),
                          ("tools/call", %*{"name": "get_weather"}),
                          ("prompts/get", %*{"name": "挨拶"}),
                          ("resources/read", %*{"uri": "file:///a b"})]:
      let params = modernParams(extra)
      var version, mcpMethod, mcpName = none(string)
      for (header, value) in modernRequestHeaders(name, params):
        case header
        of "MCP-Protocol-Version": version = some(value)
        of "Mcp-Method": mcpMethod = some(value)
        of "Mcp-Name": mcpName = some(value)
        else: discard
      check checkRequestHeaders(version, mcpMethod, mcpName, name, params).isNone

  test "Given a missing MCP-Protocol-Version header, when checked, then it is a header mismatch":
    let rejection = checkRequestHeaders(none(string), some("tools/list"), none(string),
                                        "tools/list", modernParams())
    check rejection.get.code == -32020
    check "MCP-Protocol-Version" in rejection.get.message

  test "Given a version header that differs from the body, when checked, then it is a header mismatch":
    let rejection = checkRequestHeaders(some("2025-11-25"), some("tools/list"), none(string),
                                        "tools/list", modernParams())
    check rejection.get.code == -32020

  test "Given a missing Mcp-Method header, when checked, then it is a header mismatch":
    let rejection = checkRequestHeaders(some("2026-07-28"), none(string), none(string),
                                        "tools/list", modernParams())
    check rejection.get.code == -32020
    check "Mcp-Method" in rejection.get.message

  test "Given an Mcp-Method header that differs from the body, when checked, then it is a header mismatch":
    let rejection = checkRequestHeaders(some("2026-07-28"), some("tools/call"), none(string),
                                        "tools/list", modernParams())
    check rejection.get.code == -32020

  test "Given a method header that differs only in case, when checked, then it is a header mismatch":
    let rejection = checkRequestHeaders(some("2026-07-28"), some("Tools/List"), none(string),
                                        "tools/list", modernParams())
    check rejection.get.code == -32020

  test "Given a tools/call without Mcp-Name, when checked, then it is a header mismatch":
    let rejection = checkRequestHeaders(some("2026-07-28"), some("tools/call"), none(string),
                                        "tools/call", modernParams(%*{"name": "bar"}))
    check rejection.get.code == -32020
    check "Mcp-Name" in rejection.get.message

  test "Given an Mcp-Name that differs from the body, when checked, then the message names both values as in the specification's example":
    let rejection = checkRequestHeaders(some("2026-07-28"), some("tools/call"), some("foo"),
                                        "tools/call", modernParams(%*{"name": "bar"}))
    check rejection.get.code == -32020
    check rejection.get.message ==
      "Header mismatch: Mcp-Name header value 'foo' does not match body value 'bar'"

  test "Given a Base64 Mcp-Name equal to the body after decoding, when checked, then they agree":
    check checkRequestHeaders(some("2026-07-28"), some("prompts/get"),
      some(encodeHeaderValue("挨拶")), "prompts/get",
      modernParams(%*{"name": "挨拶"})).isNone

  test "Given a malformed Mcp-Name, when checked, then it is a header mismatch":
    let rejection = checkRequestHeaders(some("2026-07-28"), some("tools/call"),
      some("=?base64?***?="), "tools/call", modernParams(%*{"name": "bar"}))
    check rejection.get.code == -32020

  test "Given a tools/list with a stray Mcp-Name, when checked, then the extra header is ignored":
    check checkRequestHeaders(some("2026-07-28"), some("tools/list"), some("anything"),
                              "tools/list", modernParams()).isNone

suite "2026-07-28: errors":

  test "Given a required capability, when the error is built, then it matches the specification's example":
    let error = missingCapabilityError(
      "Server requires the elicitation capability for this request",
      %*{"elicitation": {}})
    check error.code == -32021
    check error.data == %*{"requiredCapabilities": {"elicitation": {}}}
