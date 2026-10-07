## The pieces of OAuth that need no network: PKCE, WWW-Authenticate,
## well-known URLs, URL policy, and metadata validation. Expected values are
## taken from RFC 7636 (appendix B), RFC 8414 (3.1), RFC 9728 (3.1, 5.1) and
## the MCP authorization specification.

import std/[unittest, json, options, strutils, asyncdispatch, asyncnet, httpcore, net, nativesockets]
import auth/oauth/[pkce, challenge, urls, metadata, discovery, errors, fetch]

suite "PKCE":
  test "Given the RFC 7636 appendix B verifier, when challenged with S256, then it is the appendix B challenge":
    check codeChallengeS256("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") ==
      "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"

  test "Given a new verifier, when checked, then it is 43 unreserved characters and differs each time":
    let a = newCodeVerifier()
    let b = newCodeVerifier()
    check a.len == 43
    check isValidCodeVerifier(a)
    check a != b

  test "Given too short or reserved characters, when checked, then the verifier is invalid":
    check not isValidCodeVerifier("short")
    check not isValidCodeVerifier("a".repeat(42))
    check not isValidCodeVerifier("a".repeat(42) & "+")
    check not isValidCodeVerifier("a".repeat(129))
    check isValidCodeVerifier("a".repeat(128))

suite "WWW-Authenticate":
  test "Given the MCP 401 example, when parsed, then resource_metadata and scope are found":
    let header = "Bearer resource_metadata=\"https://mcp.example.com/.well-known/oauth-protected-resource\",\n" &
                 "                         scope=\"files:read\""
    let c = bearerChallenge([header]).get
    check c.resourceMetadata.get == "https://mcp.example.com/.well-known/oauth-protected-resource"
    check c.scope.get == "files:read"

  test "Given the MCP insufficient_scope example, when parsed, then every parameter is found":
    let header = "Bearer error=\"insufficient_scope\", scope=\"files:read files:write user:profile\", " &
                 "resource_metadata=\"https://mcp.example.com/.well-known/oauth-protected-resource\", " &
                 "error_description=\"Additional file write permission required\""
    let c = bearerChallenge([header]).get
    check c.error.get == "insufficient_scope"
    check c.scope.get == "files:read files:write user:profile"
    check c.errorDescription.get == "Additional file write permission required"

  test "Given several challenges in one header, when parsed, then the Bearer one is selected":
    let c = bearerChallenge(["Basic realm=\"x\", Bearer realm=\"mcp\", error=\"invalid_token\""]).get
    check c.realm.get == "mcp"
    check c.error.get == "invalid_token"

  test "Given a quoted string with an escaped quote and a comma, when parsed, then it is unescaped whole":
    let c = bearerChallenge(["Bearer error_description=\"say \\\"hi\\\", please\", scope=\"a\""]).get
    check c.errorDescription.get == "say \"hi\", please"
    check c.scope.get == "a"

  test "Given an unquoted token value and mixed case, when parsed, then names are case-insensitive":
    let c = bearerChallenge(["bearer Scope=read"]).get
    check c.scope.get == "read"

  test "Given only a Basic challenge or nothing, when parsed, then there is no Bearer challenge":
    check bearerChallenge(["Basic realm=\"x\""]).isNone
    check bearerChallenge(newSeq[string]()).isNone
    check bearerChallenge([""]).isNone

  test "Given garbage, when parsed, then parsing terminates":
    discard parseChallenges("=,=,\"\"\"==")
    discard parseChallenges("Bearer a=\"unterminated")

  test "Given parameters, when formatted, then quotes and backslashes are escaped":
    check formatBearerChallenge({"error": "invalid_token", "error_description": "a \"b\" \\"}) ==
      "Bearer error=\"invalid_token\", error_description=\"a \\\"b\\\" \\\\\""

  test "Given a newline in a value, when formatted, then it is refused":
    expect ValueError:
      discard formatBearerChallenge({"error_description": "x\r\nSet-Cookie: a=b"})

suite "Well-known URLs":
  test "Given an issuer with a path, when building RFC 8414 URLs, then the suffix is inserted before the path":
    check wellKnownUrl("https://auth.example.com/tenant1", "oauth-authorization-server") ==
      "https://auth.example.com/.well-known/oauth-authorization-server/tenant1"

  test "Given a trailing slash, when building the URL, then it is removed first (RFC 8414 3.1)":
    check wellKnownUrl("https://auth.example.com/issuer1/", "oauth-authorization-server") ==
      "https://auth.example.com/.well-known/oauth-authorization-server/issuer1"
    check wellKnownUrl("https://auth.example.com/", "oauth-authorization-server") ==
      "https://auth.example.com/.well-known/oauth-authorization-server"

  test "Given the MCP 2025-11-25 example issuer with a path, when listing candidates, then the order is the specified one":
    check authorizationServerMetadataUrls("https://auth.example.com/tenant1", adsOAuthThenOidc) == @[
      "https://auth.example.com/.well-known/oauth-authorization-server/tenant1",
      "https://auth.example.com/.well-known/openid-configuration/tenant1",
      "https://auth.example.com/tenant1/.well-known/openid-configuration"]

  test "Given an issuer without a path, when listing candidates, then there are two":
    check authorizationServerMetadataUrls("https://auth.example.com", adsOAuthThenOidc) == @[
      "https://auth.example.com/.well-known/oauth-authorization-server",
      "https://auth.example.com/.well-known/openid-configuration"]

  test "Given the 2025-06-18 style, when listing candidates, then OpenID Connect is not tried":
    check authorizationServerMetadataUrls("https://auth.example.com/tenant1", adsOAuthOnly) == @[
      "https://auth.example.com/.well-known/oauth-authorization-server/tenant1"]

  test "Given the MCP example server path, when listing PRM URLs, then path-specific comes before root":
    check protectedResourceMetadataUrls("https://example.com/public/mcp") == @[
      "https://example.com/.well-known/oauth-protected-resource/public/mcp",
      "https://example.com/.well-known/oauth-protected-resource"]

  test "Given a server at the root, when listing PRM URLs, then only the root is probed":
    check protectedResourceMetadataUrls("https://example.com") ==
      @["https://example.com/.well-known/oauth-protected-resource"]
    check protectedResourceMetadataUrls("https://example.com/") ==
      @["https://example.com/.well-known/oauth-protected-resource"]

suite "Canonical resource":
  test "Given the valid examples of the specification, when canonicalized, then they are unchanged":
    for url in ["https://mcp.example.com/mcp", "https://mcp.example.com",
                "https://mcp.example.com:8443", "https://mcp.example.com/server/mcp"]:
      check canonicalResource(url) == url

  test "Given uppercase scheme and host and a bare trailing slash, when canonicalized, then they are lowercased and the slash dropped":
    check canonicalResource("HTTPS://MCP.Example.COM/") == "https://mcp.example.com"

  test "Given the invalid examples of the specification, when canonicalized, then they are refused":
    expect OAuthError: discard canonicalResource("mcp.example.com")
    expect OAuthError: discard canonicalResource("https://mcp.example.com#fragment")

  test "Given the resource, when form-encoded as the specification shows, then it matches &resource=https%3A%2F%2Fmcp.example.com":
    check formEncode({"resource": "https://mcp.example.com"}) ==
      "resource=https%3A%2F%2Fmcp.example.com"

suite "Fetch policy":
  let policy = defaultFetchPolicy()

  test "Given https to a public name, when checked, then it passes":
    checkFetchUrl("https://auth.example.com/x", policy, "t")

  test "Given plain http to a remote host, when checked, then it is refused":
    expect OAuthSecurityError: checkFetchUrl("http://auth.example.com/x", policy, "t")

  test "Given plain http to loopback hosts, when checked, then it passes":
    for url in ["http://localhost:1/x", "http://127.0.0.1:8080/x", "http://[::1]:8080/x"]:
      checkFetchUrl(url, policy, "t")

  test "Given loopback disallowed, when checking loopback, then it is refused":
    var strict = policy
    strict.allowLoopback = false
    expect OAuthSecurityError: checkFetchUrl("http://127.0.0.1/x", strict, "t")
    expect OAuthSecurityError: checkFetchUrl("https://localhost/x", strict, "t")

  test "Given the cloud metadata address, when checked, then it is always refused":
    var open = policy
    open.allowPrivateNetworks = true
    expect OAuthSecurityError: checkFetchUrl("https://169.254.169.254/latest", policy, "t")
    expect OAuthSecurityError: checkFetchUrl("https://169.254.169.254/latest", open, "t")
    expect OAuthSecurityError: checkFetchUrl("https://[fe80::1]/x", open, "t")

  test "Given private ranges, when checked, then they are refused unless allowed":
    for url in ["https://10.0.0.5/x", "https://172.16.0.1/x", "https://172.31.255.255/x",
                "https://192.168.1.1/x", "https://[fd00::1]/x", "https://[::ffff:10.0.0.1]/x"]:
      expect OAuthSecurityError: checkFetchUrl(url, policy, "t")
    var open = policy
    open.allowPrivateNetworks = true
    checkFetchUrl("https://10.0.0.5/x", open, "t")
    # 172.32 is outside 172.16/12
    checkFetchUrl("https://172.32.0.1/x", policy, "t")

  test "Given other schemes, fragments or credentials, when checked, then they are refused":
    expect OAuthSecurityError: checkFetchUrl("ftp://auth.example.com/x", policy, "t")
    expect OAuthSecurityError: checkFetchUrl("file:///etc/passwd", policy, "t")
    expect OAuthSecurityError: checkFetchUrl("https://auth.example.com/x#a", policy, "t")
    expect OAuthSecurityError: checkFetchUrl("https://user:pw@auth.example.com/x", policy, "t")
    expect OAuthSecurityError: checkFetchUrl("/relative", policy, "t")

const goodAs = """{"issuer": "https://auth.example.com/tenant1",
  "authorization_endpoint": "https://auth.example.com/authorize",
  "token_endpoint": "https://auth.example.com/token",
  "registration_endpoint": "https://auth.example.com/register",
  "code_challenge_methods_supported": ["S256"],
  "client_id_metadata_document_supported": true,
  "authorization_response_iss_parameter_supported": true}"""

suite "Metadata validation":
  let policy = defaultFetchPolicy()

  test "Given a document naming the issuer it was fetched for, when parsed, then the fields are read":
    let m = parseAuthorizationServerMetadata(parseJson(goodAs), "https://auth.example.com/tenant1", policy)
    check m.tokenEndpoint == "https://auth.example.com/token"
    check m.registrationEndpoint.get == "https://auth.example.com/register"
    check m.codeChallengeMethodsSupported.get == @["S256"]
    check m.clientIdMetadataDocumentSupported
    check m.authorizationResponseIssParameterSupported

  test "Given the specification's example of an attacker serving another issuer, when parsed, then it is rejected":
    let doc = parseJson("""{"issuer": "https://honest.example",
      "authorization_endpoint": "https://attacker.example/authorize",
      "token_endpoint": "https://attacker.example/token"}""")
    expect OAuthSecurityError:
      discard parseAuthorizationServerMetadata(doc, "https://attacker.example", policy)

  test "Given an issuer differing only in a trailing slash, when parsed, then it is rejected":
    expect OAuthSecurityError:
      discard parseAuthorizationServerMetadata(parseJson(goodAs), "https://auth.example.com/tenant1/", policy)

  test "Given a plain http token endpoint on a remote host, when parsed, then it is rejected":
    let doc = parseJson(goodAs)
    doc["token_endpoint"] = %"http://auth.example.com/token"
    expect OAuthSecurityError:
      discard parseAuthorizationServerMetadata(doc, "https://auth.example.com/tenant1", policy)

  test "Given wrong types and missing fields, when parsed, then OAuthError names the field":
    for (key, value) in [("token_endpoint", newJInt(1)), ("code_challenge_methods_supported", %"S256"),
                         ("client_id_metadata_document_supported", %"yes"),
                         ("authorization_endpoint", newJNull())]:
      let doc = parseJson(goodAs)
      doc[key] = value
      expect OAuthError:
        discard parseAuthorizationServerMetadata(doc, "https://auth.example.com/tenant1", policy)
    expect OAuthError:
      discard parseAuthorizationServerMetadata(parseJson("[]"), "https://a", policy)

  test "Given no code_challenge_methods_supported, when parsed, then the field is absent rather than empty":
    let doc = parseJson(goodAs)
    doc.delete("code_challenge_methods_supported")
    let m = parseAuthorizationServerMetadata(doc, "https://auth.example.com/tenant1", policy)
    check m.codeChallengeMethodsSupported.isNone

  test "Given PRM for another resource, when parsed, then it is rejected (RFC 9728 3.3)":
    let doc = parseJson("""{"resource": "https://other.example/mcp",
      "authorization_servers": ["https://auth.example.com"]}""")
    expect OAuthSecurityError:
      discard parseProtectedResourceMetadata(doc, "https://mcp.example.com/mcp", policy)

  test "Given PRM whose resource differs only by case of host and a bare slash, when parsed, then it is accepted":
    let doc = parseJson("""{"resource": "https://MCP.example.com/",
      "authorization_servers": ["https://auth.example.com"], "scopes_supported": ["a", "b"]}""")
    let m = parseProtectedResourceMetadata(doc, "https://mcp.example.com", policy)
    check m.authorizationServers == @["https://auth.example.com"]
    check m.scopesSupported == @["a", "b"]

  test "Given PRM without authorization servers or with an insecure one, when parsed, then it is rejected":
    expect OAuthError:
      discard parseProtectedResourceMetadata(
        parseJson("""{"resource": "https://m.example", "authorization_servers": []}"""),
        "https://m.example", policy)
    expect OAuthError:
      discard parseProtectedResourceMetadata(
        parseJson("""{"resource": "https://m.example"}"""), "https://m.example", policy)
    expect OAuthSecurityError:
      discard parseProtectedResourceMetadata(
        parseJson("""{"resource": "https://m.example", "authorization_servers": ["http://a.example"]}"""),
        "https://m.example", policy)

  test "Given the 2025-03-26 defaults, when built for a server URL with a path, then they are on the origin":
    let m = defaultEndpointMetadata("https://api.example.com/v1/mcp")
    check m.authorizationEndpoint == "https://api.example.com/authorize"
    check m.tokenEndpoint == "https://api.example.com/token"
    check m.registrationEndpoint.get == "https://api.example.com/register"

suite "WWW-Authenticate edges (mutation review, g2f-oauth-a)":
  test "Given a Basic challenge with token68 padding before a Bearer one, when parsed, then the Bearer parameters are found":
    # RFC 9110 11.2: token68 may end in any number of "=".
    let header = "Basic YWJj==, Bearer resource_metadata=\"https://mcp.example.com/prm\", scope=\"read\""
    let challenges = parseChallenges(header)
    check challenges.len == 2
    check challenges[0].scheme == "Basic"
    check challenges[0].params.len == 0
    let bearer = bearerChallenge([header]).get
    check bearer.resourceMetadata == some("https://mcp.example.com/prm")
    check bearer.scope == some("read")

  test "Given a token68 whose padding ends the header, when parsed, then parsing ends with the challenge":
    let challenges = parseChallenges("Basic YWJj==")
    check challenges.len == 1
    check challenges[0].scheme == "Basic"
    check challenges[0].params.len == 0

  test "Given white space around the equals sign, when parsed, then the values are the same as without it (RFC 9110 11.2 BWS)":
    let bearer = bearerChallenge(["Bearer realm = \"a b\" , scope =  read"]).get
    check bearer.realm == some("a b")
    check bearer.scope == some("read")

  test "Given a parameter that ends the header, when parsed, then its value is empty":
    check bearerChallenge(["Bearer realm="]).get.realm == some("")
    check bearerChallenge(["Bearer realm=  "]).get.realm == some("")

  test "Given a quoted string that is cut off after a backslash, when parsed, then the backslash is kept":
    check bearerChallenge(["Bearer realm=\"a\\"]).get.realm == some("a\\")

  test "Given a header that starts with a parameter and no scheme, when parsed, then no challenge carries it":
    for c in parseChallenges("realm=\"x\""):
      check c.params.len == 0
    check bearerChallenge(["realm=\"x\", Bearer scope=\"s\""]).get.scope == some("s")

suite "Candidate URLs of an issuer with a trailing slash (mutation review, g2f-oauth-a)":
  test "Given an issuer path that ends in a slash, when listing candidates, then the slash is dropped from every URL":
    check authorizationServerMetadataUrls("https://auth.example.com/tenant1/", adsOAuthThenOidc) == @[
      "https://auth.example.com/.well-known/oauth-authorization-server/tenant1",
      "https://auth.example.com/.well-known/openid-configuration/tenant1",
      "https://auth.example.com/tenant1/.well-known/openid-configuration"]

suite "URL rules (mutation review, g2f-oauth-a)":
  let policy = defaultFetchPolicy()

  test "Given URLs that name no host or no scheme, when checked, then they are refused":
    expect OAuthSecurityError: checkFetchUrl("https:///x", policy, "t")
    expect OAuthSecurityError: checkFetchUrl("//auth.example.com/x", policy, "t")

  test "Given a user name alone or a password alone, when checked, then the URL is refused for its credentials":
    expect OAuthSecurityError: checkFetchUrl("https://user@auth.example.com/x", policy, "t")
    expect OAuthSecurityError: checkFetchUrl("https://:secret@auth.example.com/x", policy, "t")

  test "Given a resource without a host or without a scheme, when canonicalized, then it is refused":
    expect OAuthError: discard canonicalResource("https:///mcp")
    expect OAuthError: discard canonicalResource("//mcp.example.com/mcp")

  test "Given a resource with a query, when canonicalized, then the query is kept (RFC 8707 2)":
    check canonicalResource("HTTPS://MCP.example.com/api?tenant=a%20b") ==
      "https://mcp.example.com/api?tenant=a%20b"

  test "Given a field with a space, when form-encoded, then the space is %20":
    check formEncode([("scope", "read write")]) == "scope=read%20write"
