## MCP Apps, the messages between the host and a View. Specification:
## ext-apps@82221c0c8ce7661efa6771c9d461511b1650495f,
## specification/2026-01-26/apps.mdx ("Communication Protocol",
## "MCP Apps Specific Messages", "Sandbox proxy", "Lifecycle").

import std/[unittest, json, options, strutils]
import ext/apps/model
import ext/apps/messages

proc viewInit(extra: JsonNode = nil): JsonNode =
  result = %*{"appInfo": {"name": "My UI", "version": "1.0.0"}, "appCapabilities": {},
              "protocolVersion": AppsProtocolVersion}
  if not extra.isNil:
    for key, value in extra:
      result[key] = value

proc readySession(): ViewSession =
  let session = newViewSession()
  discard session.handleInitialize(viewInit(), "host", "1", %*{}, %*{"theme": "dark"})
  session.noteInitialized()
  session

suite "the handshake":

  test "Given a View's ui/initialize, when the host answers, then the result carries the version, host info, capabilities and context":
    let session = newViewSession()
    let answer = session.handleInitialize(viewInit(), "claude-desktop", "1.0.0",
      %*{"openLinks": {}, "logging": {}},
      %*{"theme": "dark", "displayMode": "inline", "containerDimensions": {"width": 400, "maxHeight": 600}})
    check answer["protocolVersion"].getStr() == AppsProtocolVersion
    check answer["hostInfo"] == %*{"name": "claude-desktop", "version": "1.0.0"}
    check answer["hostCapabilities"].hasKey("openLinks")
    check answer["hostContext"]["theme"].getStr() == "dark"
    check session.phase == vpAwaitInitialized

  test "Given the View's initialize, when it declares display modes and tools, then they are remembered":
    let session = newViewSession()
    discard session.handleInitialize(viewInit(%*{"appCapabilities": {
      "availableDisplayModes": ["inline", "fullscreen"], "tools": {"listChanged": true}}}),
      "h", "1", %*{}, %*{})
    check session.init.get.availableDisplayModes == @[udInline, udFullscreen]
    check session.init.get.toolsListChanged
    check session.init.get.appName == "My UI"

  test "Given ui/initialize without appCapabilities or with a malformed field, when handled, then McpAppsError and the session stays unstarted":
    for bad in [%*{"appInfo": {"name": "x", "version": "1"}, "protocolVersion": "2026-01-26"},
                %*{"appInfo": "x", "appCapabilities": {}, "protocolVersion": "2026-01-26"},
                %*{"appInfo": {"name": "x"}, "appCapabilities": {}, "protocolVersion": "2026-01-26"},
                %*{"appInfo": {"name": "x", "version": "1"}, "appCapabilities": {}},
                %*{"appInfo": {"name": "x", "version": "1"}, "appCapabilities": {
                   "availableDisplayModes": ["tiny"]}, "protocolVersion": "2026-01-26"},
                %*{"appInfo": {"name": "x", "version": "1"}, "appCapabilities": {"tools": 1},
                   "protocolVersion": "2026-01-26"}]:
      let session = newViewSession()
      expect McpAppsError:
        discard session.handleInitialize(bad, "h", "1", %*{}, %*{})
      check session.phase == vpAwaitInitialize

  test "Given a second ui/initialize, when handled, then McpAppsError":
    let session = readySession()
    expect McpAppsError:
      discard session.handleInitialize(viewInit(), "h", "1", %*{}, %*{})

  test "Given initialized before ui/initialize or twice, when noted, then McpAppsError":
    expect McpAppsError:
      newViewSession().noteInitialized()
    let session = readySession()
    expect McpAppsError:
      session.noteInitialized()

  test "Given a host context that breaks the specification, when the result is built, then McpAppsError":
    for bad in [%*{"theme": "blue"}, %*{"displayMode": "tiny"}, %*{"platform": "tv"},
                %*{"locale": 3}, %*{"containerDimensions": {"height": 10, "maxHeight": 20}},
                %*{"containerDimensions": {"width": -1}}, %*{"safeAreaInsets": {"top": 1}},
                %*{"deviceCapabilities": {"touch": "yes"}},
                %*{"styles": {"variables": {"--not-standard": "x"}}},
                %*{"styles": {"variables": {"--font-sans": 3}}},
                %*{"styles": {"css": {"fonts": 3}}}, %*{"toolInfo": {"id": 1}},
                %*{"availableDisplayModes": ["tiny"]}]:
      check hostContextProblem(bad).isSome
      expect McpAppsError:
        discard initializeResult("h", "1", %*{}, bad)

  test "Given a host context that is not an object or holds a section of the wrong kind, when validated, then each is a problem":
    for bad in [newJNull(), %*[1], %*"theme", %*{"displayMode": 3},
                %*{"availableDisplayModes": "inline"}, %*{"availableDisplayModes": [3]},
                %*{"containerDimensions": 3}, %*{"containerDimensions": {"width": newJFloat(Inf)}},
                %*{"containerDimensions": {"width": 400, "maxWidth": 500}},
                %*{"safeAreaInsets": 3}, %*{"deviceCapabilities": 3},
                %*{"styles": 3}, %*{"styles": {"variables": 3}}]:
      check hostContextProblem(bad).isSome
    check hostContextProblem(nil).isSome

  test "Given a host context with a list of modes and zero-pixel dimensions, when validated, then it passes":
    check hostContextProblem(%*{"availableDisplayModes": ["inline", "pip"]}).isNone
    check hostContextProblem(%*{"containerDimensions": {"height": 0, "width": 0}}).isNone

  test "Given host capabilities that are not an object, when the result is built, then McpAppsError":
    for bad in [%*[1], %*"x", newJNull()]:
      expect McpAppsError:
        discard initializeResult("h", "1", bad, %*{})
    expect McpAppsError:
      discard initializeResult("h", "1", nil, %*{})

  test "Given ui/initialize without appInfo, when handled, then McpAppsError":
    let session = newViewSession()
    expect McpAppsError:
      discard session.handleInitialize(%*{"appCapabilities": {}, "protocolVersion": "2026-01-26"},
                                       "h", "1", %*{}, %*{})
    check session.phase == vpAwaitInitialize

  test "Given a View whose tools declaration omits listChanged, when initialized, then it does not announce list changes":
    let session = newViewSession()
    discard session.handleInitialize(viewInit(%*{"appCapabilities": {"tools": {}}}),
                                     "h", "1", %*{}, %*{})
    check not session.init.get.toolsListChanged

  test "Given initialized sent twice or too early, when noted, then the error says which":
    var early = ""
    try:
      newViewSession().noteInitialized()
    except McpAppsError as e:
      early = e.msg
    check "before ui/initialize" in early
    var twice = ""
    try:
      let session = readySession()
      session.noteInitialized()
    except McpAppsError as e:
      twice = e.msg
    check "twice" in twice

  test "Given the specification's host context example, when validated, then it passes":
    check hostContextProblem(%*{"theme": "dark", "styles": {"variables": {
      "--color-background-primary": "light-dark(#ffffff, #171717)", "--font-sans": "Anthropic Sans, sans-serif"},
      "css": {"fonts": "@font-face { font-family: \"X\"; }"}}, "displayMode": "inline",
      "containerDimensions": {"width": 400, "maxHeight": 600},
      "toolInfo": {"id": 1, "tool": {"name": "t", "inputSchema": {}}},
      "locale": "en-US", "timeZone": "America/New_York", "platform": "desktop",
      "deviceCapabilities": {"touch": false, "hover": true},
      "safeAreaInsets": {"top": 0, "right": 0, "bottom": 0, "left": 0}}).isNone

suite "what the host may send, and when":

  test "Given a View that has not sent initialized, when the host sends a notification or request, then McpAppsError":
    let session = newViewSession()
    discard session.handleInitialize(viewInit(), "h", "1", %*{}, %*{})
    expect McpAppsError:
      discard session.outgoing(toolInputNotification(%*{"a": 1}))
    expect McpAppsError:
      discard session.outgoing(resourceTeardownRequest(%1))
    expect McpAppsError:
      discard session.outgoing(hostContextChangedNotification(%*{"theme": "light"}))

  test "Given a response, when the host sends it at any time, then it passes":
    let session = newViewSession()
    let response = uiResponse(%1)
    check session.outgoing(response) == response

  test "Given an initialized View, when the host sends tool-input then tool-result, then both pass":
    let session = readySession()
    discard session.outgoing(toolInputPartialNotification(%*{"loc": "San"}))
    discard session.outgoing(toolInputPartialNotification(%*{"loc": "San Fran"}))
    discard session.outgoing(toolInputNotification(%*{"location": "San Francisco"}))
    discard session.outgoing(toolResultNotification(%*{"content": []}))

  test "Given tool-result before tool-input, when sent, then McpAppsError":
    let session = readySession()
    expect McpAppsError:
      discard session.outgoing(toolResultNotification(%*{"content": []}))

  test "Given tool-input already sent, when it is sent again, then McpAppsError":
    let session = readySession()
    discard session.outgoing(toolInputNotification(%*{}))
    expect McpAppsError:
      discard session.outgoing(toolInputNotification(%*{}))

  test "Given tool-input sent, when a partial follows, then McpAppsError":
    let session = readySession()
    discard session.outgoing(toolInputNotification(%*{}))
    expect McpAppsError:
      discard session.outgoing(toolInputPartialNotification(%*{"x": 1}))

  test "Given a ready View, when the host sends a sandbox-reserved message to it, then McpAppsError":
    expect McpAppsError:
      discard readySession().outgoing(sandboxResourceReadyNotification("<html></html>"))

  test "Given a ready View, when the host cancels, changes context and tears down, then those pass":
    let session = readySession()
    discard session.outgoing(toolCancelledNotification("user"))
    discard session.outgoing(hostContextChangedNotification(%*{"displayMode": "fullscreen"}))
    discard session.outgoing(resourceTeardownRequest(%7, "done"))

suite "messages the host builds":

  test "Given arguments and a result, when the notifications are built, then they have the specification's methods and params":
    check toolInputNotification(%*{"location": "SF"}) == %*{"jsonrpc": "2.0",
      "method": "ui/notifications/tool-input", "params": {"arguments": {"location": "SF"}}}
    check toolInputPartialNotification(%*{"l": "S"})["method"].getStr() ==
      "ui/notifications/tool-input-partial"
    let result = %*{"content": [{"type": "text", "text": "ok"}], "structuredContent": {"t": 72}}
    check toolResultNotification(result)["params"] == result
    check toolResultNotification(result)["method"].getStr() == "ui/notifications/tool-result"

  test "Given arguments or a result that are not objects, when built, then McpAppsError":
    expect McpAppsError: discard toolInputNotification(%*[1])
    expect McpAppsError: discard toolInputNotification(nil)
    expect McpAppsError: discard toolInputPartialNotification(%*"x")
    expect McpAppsError: discard toolResultNotification(%*[1])

  test "Given a reason, when cancellation and teardown are built, then it travels in params":
    check toolCancelledNotification("user")["params"] == %*{"reason": "user"}
    check toolCancelledNotification()["params"] == newJObject()
    let teardown = resourceTeardownRequest(%3, "re-allocation")
    check teardown["id"].getInt() == 3
    check teardown["method"].getStr() == "ui/resource-teardown"
    check teardown["params"]["reason"].getStr() == "re-allocation"

  test "Given no reason, when teardown is built, then params are empty":
    check resourceTeardownRequest(%3)["params"] == newJObject()

  test "Given a partial context, when host-context-changed is built, then params are that context":
    check hostContextChangedNotification(%*{"theme": "light"})["params"] == %*{"theme": "light"}

  test "Given a changed context that breaks the specification, when host-context-changed is built, then McpAppsError":
    expect McpAppsError:
      discard hostContextChangedNotification(%*{"theme": "blue"})

  test "Given a denied request, when the error is built, then it has the implementation-defined code and the message":
    check uiErrorResponse(%2, "Link opening denied by user") ==
      %*{"jsonrpc": "2.0", "id": 2, "error": {"code": -32000, "message": "Link opening denied by user"}}
    check uiErrorResponse(%2, "bad", InvalidParamsError)["error"]["code"].getInt() == -32602
    check uiResponse(%2) == %*{"jsonrpc": "2.0", "id": 2, "result": {}}

suite "requests of the View":

  test "Given ui/open-link with an http or https URL, when parsed, then the URL is returned":
    check parseOpenLink(%*{"url": "https://example.com/a?b=1"}) == "https://example.com/a?b=1"
    check parseOpenLink(%*{"url": "http://localhost:8080"}) == "http://localhost:8080"

  test "Given ui/open-link with a URL the host should not open, when parsed, then McpAppsError":
    for bad in [%*{"url": "javascript:alert(1)"}, %*{"url": "file:///etc/passwd"},
                %*{"url": "data:text/html,x"}, %*{"url": "/relative"}, %*{"url": "https://"},
                %*{"url": "https://a b.com"}, %*{"url": ""}, %*{"url": 3}, %*{}, %*[1]]:
      expect McpAppsError:
        discard parseOpenLink(bad)

  test "Given ui/message with a text block, when parsed, then the block is returned whether given as an object or an array":
    let block0 = %*{"type": "text", "text": "hi"}
    check parseUiMessage(%*{"role": "user", "content": block0}) == @[block0]
    check parseUiMessage(%*{"role": "user", "content": [block0]}) == @[block0]

  test "Given ui/message that is malformed, when parsed, then McpAppsError":
    for bad in [%*{"role": "assistant", "content": {"type": "text", "text": "x"}},
                %*{"content": {"type": "text", "text": "x"}}, %*{"role": "user"},
                %*{"role": "user", "content": {"type": "text"}},
                %*{"role": "user", "content": {"type": "video"}},
                %*{"role": "user", "content": "x"},
                %*{"role": "user", "content": [1]},
                %*{"role": "user", "content": {"type": "image", "data": "x"}},
                %*{"role": "user", "content": {"type": "resource_link", "uri": "u"}},
                %*{"role": "user", "content": {"type": "resource"}}]:
      expect McpAppsError:
        discard parseUiMessage(bad)

  test "Given ui/message with a resource block, when parsed, then it is returned; one without a resource object or a type is McpAppsError":
    let resourceBlock = %*{"type": "resource", "resource": {"uri": "file:///a", "text": "x"}}
    check parseUiMessage(%*{"role": "user", "content": resourceBlock}) == @[resourceBlock]
    for bad in [%*{"type": "resource", "resource": "file:///a"}, newJObject()]:
      expect McpAppsError:
        discard parseUiMessage(%*{"role": "user", "content": bad})

  test "Given ui/update-model-context, when parsed, then content blocks and structured content are returned":
    let update = parseUpdateModelContext(%*{"content": [{"type": "text", "text": "state"}],
                                            "structuredContent": {"a": 1}})
    check update.content.len == 1
    check update.structuredContent == some(%*{"a": 1})
    check parseUpdateModelContext(newJObject()).content.len == 0

  test "Given ui/update-model-context that is malformed, when parsed, then McpAppsError":
    for bad in [%*{"content": {"type": "text", "text": "x"}}, %*{"content": [{"type": "x"}]},
                %*{"structuredContent": [1]}, %*[1]]:
      expect McpAppsError:
        discard parseUpdateModelContext(bad)

  test "Given ui/request-display-mode, when parsed, then the mode is returned; an unknown mode is McpAppsError":
    check parseRequestDisplayMode(%*{"mode": "fullscreen"}) == udFullscreen
    expect McpAppsError: discard parseRequestDisplayMode(%*{"mode": "tiny"})
    expect McpAppsError: discard parseRequestDisplayMode(%*{})

  test "Given a requested mode, when the host resolves it, then it is granted only if the host and a declaring View support it":
    let declared = ViewInit(availableDisplayModes: @[udInline, udFullscreen])
    let undeclared = ViewInit()
    check resolveDisplayMode(udFullscreen, [udInline, udFullscreen], declared, udInline) == udFullscreen
    check resolveDisplayMode(udPip, [udInline, udFullscreen, udPip], declared, udInline) == udInline
    check resolveDisplayMode(udPip, [udInline, udFullscreen], undeclared, udInline) == udInline
    check resolveDisplayMode(udPip, [udInline, udPip], undeclared, udInline) == udPip
    check displayModeResult(udInline) == %*{"mode": "inline"}

  test "Given a mode the host or the View does not support, when resolved, then the current mode is kept, whichever it is":
    let declared = ViewInit(availableDisplayModes: @[udInline, udFullscreen])
    check resolveDisplayMode(udPip, [udInline, udFullscreen], declared, udFullscreen) == udFullscreen
    check resolveDisplayMode(udPip, [udInline, udFullscreen, udPip], declared, udPip) == udPip
    check resolveDisplayMode(udPip, [udInline, udFullscreen, udPip], declared, udFullscreen) == udFullscreen

  test "Given a size of zero or a number that is not finite, when size-changed is parsed, then zero passes and the other is McpAppsError":
    check parseSizeChanged(%*{"width": 0, "height": 0}) == (width: some(0.0), height: some(0.0))
    expect McpAppsError:
      discard parseSizeChanged(%*{"width": newJFloat(Inf)})
    expect McpAppsError:
      discard parseSizeChanged(%*{"height": newJFloat(NaN)})

  test "Given ui/notifications/size-changed, when parsed, then width and height are read, each optional":
    check parseSizeChanged(%*{"width": 400, "height": 250.5}) ==
      (width: some(400.0), height: some(250.5))
    check parseSizeChanged(%*{"height": 10}).width.isNone
    for bad in [%*{"width": -1}, %*{"height": "tall"}, %*[1]]:
      expect McpAppsError:
        discard parseSizeChanged(bad)

suite "sandbox proxy":

  test "Given the ready and resource-ready messages, when built, then they have the specification's shape":
    check sandboxProxyReadyNotification() == %*{"jsonrpc": "2.0",
      "method": "ui/notifications/sandbox-proxy-ready", "params": {}}
    let ready = sandboxResourceReadyNotification("<html></html>",
      some(UiCsp(connectDomains: @["https://api.example.com"])), {upCamera}, sandbox = "allow-scripts allow-same-origin")
    check ready["method"].getStr() == "ui/notifications/sandbox-resource-ready"
    check ready["params"]["html"].getStr() == "<html></html>"
    check ready["params"]["csp"]["connectDomains"][0].getStr() == "https://api.example.com"
    check ready["params"]["permissions"].hasKey("camera")
    check ready["params"]["sandbox"].getStr() == "allow-scripts allow-same-origin"
    check not sandboxResourceReadyNotification("x")["params"].hasKey("csp")
    check not sandboxResourceReadyNotification("x")["params"].hasKey("sandbox")

  test "Given a csp with a bad origin, when sandbox-resource-ready is built, then McpAppsError":
    expect McpAppsError:
      discard sandboxResourceReadyNotification("x", some(UiCsp(connectDomains: @["*"])))

  test "Given methods, when routed, then the sandbox forwards all but ui/notifications/sandbox-* and the host forwards to the server only non-ui methods":
    check isSandboxReserved("ui/notifications/sandbox-proxy-ready")
    check isSandboxReserved("ui/notifications/sandbox-resource-ready")
    check not isSandboxReserved("ui/notifications/initialized")
    check mayCrossSandbox("ui/initialize")
    check mayCrossSandbox("tools/call")
    check not mayCrossSandbox("ui/notifications/sandbox-resource-ready")
    check mayForwardToServer("tools/call")
    check mayForwardToServer("resources/read")
    check mayForwardToServer("notifications/message")
    check not mayForwardToServer("ui/open-link")
    check not mayForwardToServer("ui/notifications/size-changed")
