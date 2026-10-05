Feature: Authorization extensions (ext-auth)
  As an application that needs machine-to-machine or enterprise-managed access to an MCP server
  I want the official authorization extensions, switched on explicitly
  So that the core authorization flow stays what the dated specifications say

  Source: modelcontextprotocol/ext-auth at fb374c7db2b34f18ca9183882e0beecdf661892b
  (specification/draft/oauth-client-credentials.mdx, a draft;
  specification/stable/enterprise-managed-authorization.mdx) and
  docs/extensions/auth/ of the specification repository at
  75db1e987cbbba6d170315dc99d0dfc440754aef. What was and was not settled by those texts:
  docs/quality/ext-auth.md. The extensions are not in `mcp.nim`; an application imports
  `ext/auth_client_credentials` or `ext/auth_enterprise_managed` and registers what it uses.

  @spec:MCP-EXT-AUTH-1
  Scenario: A client with its own credentials gets a token without a user
    Given an MCP server that answers 401 and an authorization server that authenticates clients
    When a client with a client secret or a signing key sends a request
    Then it discovers the authorization server, requests a client_credentials token with the resource, retries with it, reuses it, and replaces it when it has expired

  @spec:MCP-EXT-AUTH-2
  Scenario: The scope comes from the config, the challenge or scopes_supported, and a 403 asks for more once
    Given a resource server that names scopes in its challenge, in its metadata or in a 403
    When the client requests a token
    Then it asks for the config's scopes, else the challenge's, else scopes_supported, and after insufficient_scope for the union, but not again for scopes it already asked for

  @spec:MCP-EXT-AUTH-3
  Scenario: Credentials are sent only to a server that advertises what the draft requires
    Given authorization server metadata without token_endpoint_auth_methods_supported, without private_key_jwt or client_secret_basic, without the signer's algorithm, or without the client_credentials grant
    When the client would authenticate
    Then it refuses before anything is sent to the token endpoint

  @spec:MCP-EXT-AUTH-4
  Scenario: Failures and refusals carry no secret and never go to a server the client did not vet
    Given a wrong secret, a wrong key, a failing signer, an unlisted or mismatched authorization server, a plain-http token endpoint or a token response that is not Bearer
    When the client requests a token
    Then the failure is reported without the secret, the key or the signer's message, and no credential is sent to an unvetted server

  @spec:MCP-EXT-AUTH-5
  Scenario: The extension is off unless the application uses it
    Given a transport without the extension's auth, or a configuration that could never succeed
    When a request is answered 401 or the auth is made
    Then no token is requested, and a bad configuration raises ValueError

  @spec:MCP-EXT-AUTH-6
  Scenario: The extension is declared in the extensions capability only when asked
    Given a client or server that calls declare or advertise for the extension
    When a 2026-07-28 client sends a request or discovers the server
    Then io.modelcontextprotocol/oauth-client-credentials is listed with empty settings, otherwise not, and a build without the extensions capability raises ValueError

  @spec:MCP-EXT-AUTH-7
  Scenario: The token endpoint requests and JWTs the extensions use follow the RFCs
    Given a token endpoint that authenticates clients by Basic, body secret, private_key_jwt or none
    When client credentials, the JWT bearer grant or a token exchange is requested, or a JWT is signed and read
    Then each request has the RFC's parameters, the signer is the application's, "none" and malformed JWTs are refused, and no secret reaches an error message

  @spec:MCP-EXT-AUTH-8
  Scenario: A client with an identity assertion gets an access token through an ID-JAG, without a user step
    Given an MCP server that answers 401, an enterprise IdP that exchanges identity assertions, and an authorization server that accepts ID-JAGs
    When a client holding an ID token, a SAML assertion or a refresh token sends a request
    Then the IdP exchange asks for an ID-JAG for that authorization server and resource, the authorization server turns it into an access token restricted to the MCP server, the user is never sent to an authorization endpoint, and the ID-JAG is presented again before a new exchange is made

  @spec:MCP-EXT-AUTH-9
  Scenario: The exchange asks for the config's scopes, the challenge's or scopes_supported, and a 403 asks for more once
    Given a resource server that names scopes in its challenge, in its metadata or in a 403
    When the client requests an ID-JAG
    Then the scope is the config's, else the challenge's, else scopes_supported, after insufficient_scope the union, and not again for scopes already asked for

  @spec:MCP-EXT-AUTH-10
  Scenario: The identity assertion is used only with servers that advertise the profile
    Given an authorization server without authorization_grant_profiles_supported listing the id-jag profile or without the jwt-bearer grant, or an IdP that lists token types without id-jag
    When the client would authorize
    Then it refuses before the identity assertion is asked for or sent anywhere

  @spec:MCP-EXT-AUTH-11
  Scenario: The client does not present an ID-JAG that was not issued for this exchange
    Given an ID-JAG with the wrong typ, issuer, audience, client_id or resource, an expired one, one missing sub, jti, iat or exp, or an exchange response of the wrong type
    When it arrives from the IdP
    Then it is not presented to the authorization server, and an aud array of exactly the authorization server and a resource array containing the MCP server are accepted

  @spec:MCP-EXT-AUTH-12
  Scenario: Failures carry no token or secret, and each credential goes only where it belongs
    Given an IdP or authorization server that refuses, a single sign-on that has to be repeated, an IdP issuer or metadata that is not trustworthy
    When the client authorizes
    Then the failure names the OAuth error and none of the identity assertion, the ID-JAG or the secrets, the identity assertion goes to the IdP only and the ID-JAG to the authorization server only

  @spec:MCP-EXT-AUTH-13
  Scenario: Enterprise-managed authorization is off unless the application uses it
    Given a transport without the extension's auth, or a configuration that could never succeed
    When a request is answered 401 or the auth is made
    Then neither the IdP nor the authorization server is contacted, and a bad configuration raises ValueError

  @spec:MCP-EXT-AUTH-14
  Scenario: The extension is declared in the extensions capability only when asked
    Given a client or server that calls declare or advertise for the extension
    When a 2026-07-28 client sends a request or discovers the server
    Then io.modelcontextprotocol/enterprise-managed-authorization is listed with empty settings, otherwise not, and a build without the extensions capability raises ValueError
