## MCP Apps (io.modelcontextprotocol/ui), the data: UI URIs, `_meta.ui` of a
## resource and of a tool, the CSP and permission policy a host builds, and
## the capability a host declares. Specification:
## ext-apps@82221c0c8ce7661efa6771c9d461511b1650495f,
## specification/2026-01-26/apps.mdx.

import std/[unittest, json, options, strutils]
import ext/apps/model

suite "UI resource URIs":

  test "Given the specification's example URIs, when checked, then they are UI resource URIs":
    check uiUriProblem("ui://weather-dashboard").isNone
    check uiUriProblem("ui://weather-server/dashboard-template").isNone

  test "Given URIs that are not ui:// or name nothing, when checked, then each is refused":
    for bad in ["https://x/y", "ui:/x", "UI://x", "ui://", "", "file:///etc/passwd"]:
      check uiUriProblem(bad).isSome

  test "Given a URI with whitespace or a control character, when checked, then it is refused":
    for bad in ["ui://a b", "ui://a\tb", "ui://a\nb", "ui://a\x7fb"]:
      check uiUriProblem(bad).isSome

suite "metadata of a UI resource":

  const specExample = """{
    "csp": {"connectDomains": ["https://api.openweathermap.org"],
            "resourceDomains": ["https://cdn.jsdelivr.net"]},
    "prefersBorder": true}"""

  test "Given the specification's resources/read example, when parsed and written, then it round-trips":
    let node = parseJson(specExample)
    let meta = parseUiResourceMeta(node)
    check meta.csp.get.connectDomains == @["https://api.openweathermap.org"]
    check meta.csp.get.resourceDomains == @["https://cdn.jsdelivr.net"]
    check meta.prefersBorder == some(true)
    check meta.toJson == node

  test "Given every field, when parsed, then csp lists, permissions, domain and prefersBorder are read":
    let meta = parseUiResourceMeta(%*{
      "csp": {"connectDomains": ["wss://realtime.service.com"],
              "resourceDomains": ["https://*.cloudflare.com"],
              "frameDomains": ["https://www.youtube.com"],
              "baseUriDomains": ["https://cdn.example.com"]},
      "permissions": {"camera": {}, "microphone": {}, "geolocation": {}, "clipboardWrite": {}},
      "domain": "a904794854a047f6.claudemcpcontent.com", "prefersBorder": false})
    check meta.csp.get.frameDomains == @["https://www.youtube.com"]
    check meta.csp.get.baseUriDomains == @["https://cdn.example.com"]
    check meta.permissions == {upCamera, upMicrophone, upGeolocation, upClipboardWrite}
    check meta.domain == some("a904794854a047f6.claudemcpcontent.com")
    check meta.prefersBorder == some(false)
    check parseUiResourceMeta(meta.toJson) == meta

  test "Given nothing declared, when parsed, then csp is none and the permission set is empty":
    for node in [JsonNode(nil), newJObject()]:
      let meta = parseUiResourceMeta(node)
      check meta.csp.isNone
      check meta.permissions == {}
      check meta.toJson.len == 0

  test "Given fields of the wrong type, when parsed, then McpAppsError names the field":
    for (node, field) in [(%*{"csp": []}, "csp"), (%*{"csp": {"connectDomains": "x"}}, "connectDomains"),
                          (%*{"csp": {"connectDomains": [1]}}, "connectDomains"),
                          (%*{"permissions": []}, "permissions"),
                          (%*{"permissions": {"camera": true}}, "camera"),
                          (%*{"domain": 3}, "domain"), (%*{"prefersBorder": "yes"}, "prefersBorder"),
                          (%*[1], "_meta.ui")]:
      try:
        discard parseUiResourceMeta(node)
        fail()
      except McpAppsError as e:
        check field in e.msg

  test "Given a permission the SDK does not know, when parsed, then it is not granted":
    check parseUiResourceMeta(%*{"permissions": {"payment": {}, "camera": {}}}).permissions == {upCamera}

suite "origins in a CSP declaration":

  test "Given the specification's origin forms, when checked, then they are accepted":
    for ok in ["https://api.weather.com", "wss://realtime.service.com", "https://*.example.com",
               "https://cdn.jsdelivr.net", "http://localhost:3000", "https://x.example.com:8443"]:
      check cspProblem(UiCsp(connectDomains: @[ok])).isNone

  test "Given a host that starts, ends or continues with a digit, when checked, then it is accepted":
    for ok in ["https://127.0.0.1:8080", "https://1abc.example.com", "https://abc1.example.com",
               "https://a1b.example.com"]:
      check cspProblem(UiCsp(connectDomains: @[ok])).isNone

  test "Given a source that could end or extend a directive, when checked, then it is refused":
    for bad in ["https://a.com; script-src *", "https://a.com https://b.com", "'unsafe-eval'",
                "*", "https://a.com,b", "https://a.com'", "data:", "blob:", "javascript:alert(1)",
                "https://", "a.com", "https://*", "https://a..com", "https://a.com:", "https://-a.com",
                "https://a.com/path", "https://a.com\n", "https://a.com:80a"]:
      for csp in [UiCsp(connectDomains: @[bad]), UiCsp(resourceDomains: @[bad]),
                  UiCsp(frameDomains: @[bad]), UiCsp(baseUriDomains: @[bad])]:
        check cspProblem(csp).isSome

  test "Given a declaration with a bad origin, when parsed, then McpAppsError":
    expect McpAppsError:
      discard parseUiResourceMeta(%*{"csp": {"connectDomains": ["https://a.com; img-src *"]}})

  test "Given a domain with whitespace or an empty one, when checked, then it is refused":
    check metaProblem(UiResourceMeta(domain: some("a b"))).isSome
    check metaProblem(UiResourceMeta(domain: some(""))).isSome
    check metaProblem(UiResourceMeta(domain: some("www-example-com.oaiusercontent.com"))).isNone

suite "tool UI references":

  test "Given the specification's tool example, when read, then resourceUri and visibility are read":
    let meta = parseUiToolMeta(%*{"ui": {"resourceUri": "ui://weather-server/dashboard-template",
                                         "visibility": ["model", "app"]}})
    check meta.get.resourceUri == some("ui://weather-server/dashboard-template")
    check meta.get.visibility == {tvModel, tvApp}

  test "Given an app-only tool, when read, then visibility is app alone":
    let meta = parseUiToolMeta(%*{"ui": {"resourceUri": "ui://w/d", "visibility": ["app"]}})
    check meta.get.visibility == {tvApp}

  test "Given no visibility, when read, then it defaults to model and app":
    check parseUiToolMeta(%*{"ui": {"resourceUri": "ui://w/d"}}).get.visibility == {tvModel, tvApp}

  test "Given an explicit empty visibility, when read, then neither may use the tool":
    check parseUiToolMeta(%*{"ui": {"resourceUri": "ui://w/d", "visibility": []}}).get.visibility == {}

  test "Given only the deprecated flat key, when read, then it supplies the resourceUri":
    let meta = parseUiToolMeta(%*{"ui/resourceUri": "ui://w/d"})
    check meta.get.resourceUri == some("ui://w/d")
    check meta.get.visibility == {tvModel, tvApp}

  test "Given both forms, when read, then the nested one wins":
    let meta = parseUiToolMeta(%*{"ui": {"resourceUri": "ui://new"}, "ui/resourceUri": "ui://old"})
    check meta.get.resourceUri == some("ui://new")

  test "Given no UI reference, when read, then none":
    check parseUiToolMeta(nil).isNone
    check parseUiToolMeta(newJObject()).isNone
    check parseUiToolMeta(%*{"other": 1}).isNone

  test "Given malformed references, when read, then McpAppsError":
    for bad in [%*{"ui": 3}, %*{"ui": {"resourceUri": 3}}, %*{"ui": {"resourceUri": "https://x"}},
                %*{"ui": {"visibility": "app"}}, %*{"ui": {"visibility": ["admin"]}},
                %*{"ui": {"visibility": [1]}}, %*{"ui/resourceUri": 3},
                %*{"ui/resourceUri": "http://evil"}]:
      expect McpAppsError:
        discard parseUiToolMeta(bad)

  test "Given csp or permissions on a tool, when read, then McpAppsError because they belong to the resource":
    for bad in [%*{"ui": {"resourceUri": "ui://w/d", "csp": {}}},
                %*{"ui": {"resourceUri": "ui://w/d", "permissions": {}}}]:
      expect McpAppsError:
        discard parseUiToolMeta(bad)

  test "Given a tool meta, when written, then it reads back the same":
    let meta = UiToolMeta(resourceUri: some("ui://w/d"), visibility: {tvApp})
    check parseUiToolMeta(%*{"ui": meta.toJson}).get == meta

suite "the CSP a host enforces":

  test "Given no csp declared, when the CSP is built, then it is the restrictive default":
    let csp = contentSecurityPolicy(none(UiCsp))
    for directive in ["default-src 'none'", "script-src 'self' 'unsafe-inline'",
                      "style-src 'self' 'unsafe-inline'", "img-src 'self' data:",
                      "media-src 'self' data:", "connect-src 'none'", "frame-src 'none'",
                      "object-src 'none'", "base-uri 'self'"]:
      check directive in csp.split("; ")

  test "Given the specification's example declaration, when the CSP is built, then the origins land in their directives":
    let csp = contentSecurityPolicy(some(UiCsp(
      connectDomains: @["https://api.openweathermap.org"],
      resourceDomains: @["https://cdn.jsdelivr.net", "https://*.cloudflare.com"])))
    let directives = csp.split("; ")
    check "connect-src 'self' https://api.openweathermap.org" in directives
    check "script-src 'self' 'unsafe-inline' https://cdn.jsdelivr.net https://*.cloudflare.com" in directives
    check "style-src 'self' 'unsafe-inline' https://cdn.jsdelivr.net https://*.cloudflare.com" in directives
    check "img-src 'self' data: https://cdn.jsdelivr.net https://*.cloudflare.com" in directives
    check "font-src 'self' https://cdn.jsdelivr.net https://*.cloudflare.com" in directives
    check "media-src 'self' data: https://cdn.jsdelivr.net https://*.cloudflare.com" in directives
    check "frame-src 'none'" in directives
    check "base-uri 'self'" in directives
    check "object-src 'none'" in directives
    check "default-src 'none'" in directives

  test "Given only connect origins, when the CSP is built, then the resource directives are the plain ones":
    let directives = contentSecurityPolicy(some(UiCsp(
      connectDomains: @["https://api.example.com"]))).split("; ")
    for directive in ["script-src 'self' 'unsafe-inline'", "style-src 'self' 'unsafe-inline'",
                      "img-src 'self' data:", "font-src 'self'", "media-src 'self' data:"]:
      check directive in directives

  test "Given frame and base-uri origins, when the CSP is built, then they replace the 'none' and 'self' defaults":
    let csp = contentSecurityPolicy(some(UiCsp(
      frameDomains: @["https://www.youtube.com", "https://player.vimeo.com"],
      baseUriDomains: @["https://cdn.example.com"])))
    let directives = csp.split("; ")
    check "frame-src https://www.youtube.com https://player.vimeo.com" in directives
    check "base-uri https://cdn.example.com" in directives
    check "connect-src 'self'" in directives

  test "Given an origin nobody checked, when the CSP is built, then McpAppsError and no origin is let through":
    expect McpAppsError:
      discard contentSecurityPolicy(some(UiCsp(connectDomains: @["https://a.com; script-src *"])))

  test "Given declared permissions, when the allow attribute is built, then each maps to its Permission Policy feature":
    check permissionPolicy({}) == ""
    check permissionPolicy({upCamera}) == "camera"
    check permissionPolicy({upCamera, upMicrophone, upGeolocation, upClipboardWrite}) ==
      "camera microphone geolocation clipboard-write"

suite "the capability a host declares":

  test "Given the specification's example, when parsed, then the mime types are read":
    let capability = parseUiClientCapability(%*{"mimeTypes": ["text/html;profile=mcp-app"]})
    check capability.get.mimeTypes == @[ResourceMimeType]
    check capability.get.supportsHtmlApps

  test "Given a declaration without mimeTypes or with a wrong shape, when parsed, then it is none":
    for bad in [newJObject(), %*{"mimeTypes": "text/html"}, %*{"mimeTypes": [1]}, %*[1], JsonNode(nil)]:
      check parseUiClientCapability(bad).isNone

  test "Given a host that lists other mime types only, when asked, then it does not support HTML apps":
    check not parseUiClientCapability(%*{"mimeTypes": ["text/uri-list"]}).get.supportsHtmlApps
    check not parseUiClientCapability(%*{"mimeTypes": []}).get.supportsHtmlApps
