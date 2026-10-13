Feature: Authorization
  As the operator of a protected MCP server and the user of a client that reaches it
  I want the client to obtain a token the way OAuth 2.1 and MCP describe, and the server to accept only valid ones
  So that a server's tools are reached only by those it allows

  Specification: basic/authorization of 2025-03-26, 2025-06-18 and 2025-11-25,
  and of 2026-07-28 (basic/authorization/ and its pages on discovery, client
  registration and security). The versions differ and each Scenario says
  which it holds for: 2025-03-26 has no protected resource metadata and uses
  default endpoints; 2025-06-18 adds protected resource metadata and resource
  indicators; 2025-11-25 adds OpenID Connect discovery, Client ID Metadata
  Documents, scopes in the challenge and step-up; 2026-07-28 adds the iss
  check and binds credentials to their issuer. Authorization applies to
  HTTP transports only.

  # The resource server

  @spec:MCP-AUTH-1 @feature:ftAuthorization
  Scenario: A request without a valid token is 401 with a Bearer challenge
    Given a protected MCP endpoint
    When a request has no token, or a token the verifier rejects
    Then the answer is 401 with a WWW-Authenticate Bearer challenge, invalid_token for a rejected token
    And nothing reaches the verifier when there is no token

  @spec:MCP-AUTH-2 @feature:ftAuthorization
  Scenario: A valid token reaches the MCP server and nothing else does
    Given a protected MCP endpoint
    When a request carries a Bearer token the verifier accepts, the scheme in any letter case
    Then the request reaches the MCP server
    And an Authorization header that is not a Bearer token is 401 and never reaches the verifier
    And a token in the query string is not looked at
    And a verifier that fails gives 500 and the request does not go through

  @spec:MCP-AUTH-32 @feature:ftAuthorization
  Scenario: The challenge says what is wrong and no more
    Given a protected MCP endpoint
    When a request has no token, a token the verifier rejects, or a token that lacks scope
    Then a request without a token gets a challenge with no error code
    And a rejected token gets invalid_token with a description
    And a token that lacks scope gets insufficient_scope with no description
    And the metadata document lists scopes_supported only when scopes are configured

  @spec:MCP-AUTH-33 @feature:ftAuthorization
  Scenario: A token of unreasonable length, a verifier that fails and an unwritable scope are refused and reported
    Given a protected MCP endpoint
    When a token is longer than 8192 characters, the verifier fails, or the verifier names a scope that cannot go in a header
    Then a token of up to 8192 characters reaches the verifier and a longer one does not
    And a failing verifier is named on stderr without the token, and the answer is 500
    And an unwritable scope is 500 without a challenge, and stderr says so

  @spec:MCP-AUTH-3 @feature:ftAuthorization
  Scenario: The token is checked against this server as its audience
    Given a protected MCP endpoint
    When a token arrives
    Then the verifier is given the canonical URI of this server to check the audience against

  @spec:MCP-AUTH-4 @feature:ftAuthorization
  Scenario: A token without the needed scope is 403 insufficient_scope
    Given a protected MCP endpoint and a verifier that finds the token lacks scope
    When the request is posted
    Then the answer is 403 insufficient_scope naming all the scopes needed

  @spec:MCP-AUTH-5 @feature:ftAuthorization
  Scenario: Authorization applies to every HTTP request
    Given a protected MCP endpoint
    When GET or DELETE arrives without a token
    Then it is 401 too
    And a client with a token puts it on every POST, on the GET stream and on DELETE, and without authorization sends no Authorization header
    And no token appears in any URL the client requests

  @spec:MCP-AUTH-6 @feature:ftProtectedResourceMetadata
  Scenario: From 2025-06-18 the server publishes protected resource metadata
    Given a protected MCP endpoint of 2025-06-18 or later
    When the well-known URI for the endpoint is requested without a token
    Then the document names the resource and its authorization servers
    And the 401 challenge carries resource_metadata, naming that URI
    And the metadata is not served to a POST

  @spec:MCP-AUTH-7 @feature:ftAuthorization
  Scenario: 2025-03-26 has no protected resource metadata
    Given a protected MCP endpoint of 2025-03-26
    When the well-known URI is requested
    Then it is not served, and the challenge carries no resource_metadata

  @spec:MCP-AUTH-8 @feature:ftIncrementalScopeConsent
  Scenario: From 2025-11-25 the challenge names the scopes
    Given a protected MCP endpoint with scopes configured
    When a request has no token
    Then the challenge carries scope in 2025-11-25 and later, and not before

  @spec:MCP-AUTH-9 @feature:ftAuthorization
  Scenario: A client connects to a protected server and lists tools
    Given a protected server and an authorization server
    When a client connects
    Then it authorizes and lists tools through the protected endpoint

  # What the client reads from the server's answers

  @spec:MCP-AUTH-10 @feature:ftAuthorization
  Scenario: A client reads the Bearer challenge
    Given the WWW-Authenticate headers of the specification's examples
    When the client parses them
    Then it finds resource_metadata, scope and error, selects the Bearer challenge among several, and reads quoted strings whole
    And a header a resource server writes escapes quotes and backslashes in a scope and refuses a line break

  # Discovery

  @spec:MCP-AUTH-11 @feature:ftAuthDefaultEndpoints
  Scenario: 2025-03-26 discovers metadata at the origin and falls back to default endpoints
    Given a server of 2025-03-26
    When the client discovers
    Then it asks the origin's well-known URI with MCP-Protocol-Version and asks no resource metadata
    And without metadata (404) it uses /authorize, /token and /register on the origin
    And a failure other than 404 does not make it fall back

  @spec:MCP-AUTH-12 @feature:ftProtectedResourceMetadata
  Scenario: From 2025-06-18 the client finds the authorization server through the resource's metadata
    Given a server of 2025-06-18 or later
    When the challenge names resource_metadata
    Then the client uses that URL
    And the metadata of another resource is refused, as one without authorization servers or with an insecure one
    And a resource that differs only by the case of the host or a bare slash is accepted
    And in 2025-06-18, which defines no other way, a challenge without resource_metadata is a failure

  @spec:MCP-AUTH-13 @feature:ftProtectedResourceMetadata
  Scenario: From 2025-11-25 the client probes well-known URIs when the challenge names none
    Given a server of 2025-11-25 or later
    When the challenge has no resource_metadata
    Then the client probes the path-specific URI first and falls back to the root
    And a server at the root is probed at the root only

  @spec:MCP-AUTH-14 @feature:ftAuthorizationServerMetadata
  Scenario: The client finds and checks the authorization server metadata
    Given an issuer, with or without a path
    When the client builds the RFC 8414 URLs
    Then the well-known suffix goes before the path, a trailing slash is removed first, and an issuer without a path has two candidates
    And a document whose issuer differs from the issuer it was fetched for is not used, even by a trailing slash
    And wrong types, missing fields and a plain http token endpoint on a remote host are refused

  @spec:MCP-AUTH-15 @feature:ftOidcDiscovery
  Scenario: From 2025-11-25 the client also tries OpenID Connect discovery, in the specified order
    Given an issuer with a path and metadata only at the OpenID Connect path-appending URL
    When version 2025-11-25 discovers
    Then it tries the three URLs in the specified order and finds it
    And version 2025-06-18 does not try OpenID Connect

  @spec:MCP-AUTH-16 @feature:ftAuthorization
  Scenario: The client does not fetch metadata from where it should not
    Given a challenge whose resource_metadata names the cloud metadata address
    When the client discovers
    Then it is refused without a request
    And an authorization server metadata document that is too large is refused
    And a redirect of a metadata request is not followed

  # Authorizing

  @spec:MCP-AUTH-17 @feature:ftAuthorization
  Scenario: A client authorizes once on 401 and keeps the token
    Given a server that answers 401
    When a request is sent
    Then the client authorizes once and the request succeeds, the token going to the resource server and to nowhere else
    And a second request carries the token and no new authorization happens

  @spec:MCP-AUTH-18 @feature:ftAuthorization
  Scenario: The authorization code flow uses PKCE S256, state and a redirect URI that is safe
    Given an authorization server
    When the user is sent to the authorization endpoint
    Then the request carries a code_challenge by S256 and a state, and the token request carries the verifier of this request
    And the challenge of the RFC 7636 appendix B verifier is the one the RFC gives, and a verifier is 43 unreserved characters and differs each time
    And a redirect URI that is neither https nor localhost is refused

  @spec:MCP-AUTH-19 @feature:ftAuthorization
  Scenario: A response whose state does not match, or that has none, is discarded
    Given a client that sent a state
    When the redirect comes back with another state, without state, or with an error because the user denied consent
    Then the first two are discarded before any token request, and the third fails the request and says why

  @spec:MCP-AUTH-20 @feature:ftAuthorization
  Scenario: The client refuses an authorization server that cannot do PKCE S256
    Given an authorization server that advertises no PKCE support or only the plain method
    When version 2025-11-25 or later discovers it
    Then the client refuses to proceed, and a server that advertises only plain is refused by every version
    And in 2025-06-18 an absent field does not stop the client, the version having no such check

  @spec:MCP-AUTH-21 @feature:ftResourceIndicators
  Scenario: From 2025-06-18 the client sends the resource parameter, as the canonical URI
    Given a client of 2025-06-18 or later
    When the authorization request and the token request go out
    Then each carries resource, and 2025-03-26 sends none
    And the canonical URI has the scheme and host in lowercase and no bare trailing slash, the invalid examples of the specification are refused, and the form encoding is the one the specification shows

  @spec:MCP-AUTH-22 @feature:ftAuthorization
  Scenario: The client chooses its scopes the way the specification orders them
    Given an authorization
    When the challenge names scope, or there is none but scopes_supported, or neither
    Then the client asks for exactly the challenged scope, else for all scopes_supported, else omits scope
    And a choice the application made wins

  @spec:MCP-AUTH-23 @feature:ftIncrementalScopeConsent
  Scenario: A 403 insufficient_scope is answered by a step-up from 2025-11-25
    Given a client holding a token
    When the server answers 403 insufficient_scope in 2025-11-25 or later
    Then the client asks for the challenged scope and the request succeeds, the client stopping after its attempt limit when the server keeps challenging
    And in 2026-07-28 it asks for the union of the earlier and the challenged scopes
    And before 2025-11-25 it reports the error without a new authorization

  @spec:MCP-AUTH-24 @feature:ftDynamicClientRegistration
  Scenario: A client registers dynamically as a public client
    Given an authorization server that accepts registration
    When the client first authorizes
    Then it registers a public client whose redirect_uris holds its redirect URI, with application_type native from 2026-07-28
    And credentials from dynamic registration are reused when a second authorization is needed
    And when the resource now names another authorization server it registers again

  @spec:MCP-AUTH-25 @feature:ftDynamicClientRegistration
  Scenario: A client uses credentials it was given
    Given a client with pre-registered credentials
    When it authorizes
    Then it uses them and does not register, a secret going in HTTP Basic and not in the body
    And in 2026-07-28 credentials of another issuer, or without an issuer, are refused: they must be bound to the issuer

  @spec:MCP-AUTH-26 @feature:ftClientIdMetadataDocuments
  Scenario: From 2025-11-25 a client may identify itself by the URL of its metadata document
    Given an authorization server that advertises client_id_metadata_document_supported
    When the client has such a URL
    Then it uses it as its client_id and does not register
    And a URL without a path, or over http, is refused
    And a server that does not advertise support is registered with dynamically

  @spec:MCP-AUTH-27 @feature:ftIssuerParameter
  Scenario: From 2026-07-28 the client checks iss before it sends the code anywhere
    Given the issuer recorded from the validated metadata
    When the authorization response carries another iss, or none though the metadata advertises it, or an iss differing only by a trailing slash
    Then the code is never sent
    And an error response with a wrong iss is not acted on or shown
    And metadata that does not advertise iss and a response without it go on, but a wrong iss is rejected

  @spec:MCP-AUTH-28 @feature:ftAuthorization
  Scenario: Before 2026-07-28 the iss parameter is not part of the flow
    Given a client of 2025-11-25
    When the response carries a wrong iss
    Then the flow completes

  @spec:MCP-AUTH-29 @feature:ftAuthorization
  Scenario: An expired or revoked token is renewed, and the stored one is used first
    Given a client holding an access token and a refresh token
    When the access token has expired, or the server answers 401 to a revoked one
    Then the client refreshes without the user
    And when the refresh token is spent it authorizes again
    And a new client with a persisted token store presents the stored token first

  @spec:MCP-AUTH-30 @feature:ftAuthorization
  Scenario: Authorization endpoints are reached over HTTPS only
    Given an authorization server URL
    When it is https to a public name, plain http to loopback, plain http to a remote host, or in a private range
    Then https and loopback pass, and plain http to a remote host and private ranges are refused unless allowed, loopback too when disallowed
    And the cloud metadata address is always refused, as are other schemes, fragments and credentials

  @spec:MCP-AUTH-31
  Scenario: A refusal that authorization cannot overcome is reported as an authorization failure
    Given a server that answers 401 or 403, and a transport whose authorization can do nothing, fails, keeps being refused, or is absent
    When a request is sent, or a client connects
    Then it fails with McpAuthorizationError carrying the HTTP status and, when the authorization failed, its error
    And a client that probes for the server's protocol version does not go on to the handshake of another version

  @spec:MCP-AUTH-34 @feature:ftAuthorization
  Scenario: A Bearer challenge is read whatever surrounds its parameters
    Given WWW-Authenticate headers with token68 padding before a Bearer challenge, white space around the equals sign, a parameter that ends the header, a quoted string cut off after a backslash, or a parameter before any scheme
    When the client parses them
    Then the Bearer parameters are found, an empty value is empty, and a parameter without a scheme belongs to no challenge

  @spec:MCP-AUTH-35 @feature:ftAuthorization
  Scenario: Discovery uses only a 200 with a JSON object and says what each URL answered
    Given an issuer or a resource whose well-known URLs answer 201, a 200 that is no JSON object, another issuer's document, a document without a token endpoint, or 404
    When the client discovers
    Then none of them is used, a document naming another issuer is a security failure and the others are not, and the error names every URL tried with what it answered
    And an issuer with a fragment is refused before any request, and the candidate URLs of an issuer path that ends in a slash have the slash dropped

  @spec:MCP-AUTH-36 @feature:ftAuthorization
  Scenario: The OAuth client never follows a redirect and does not leave a connection open
    Given an endpoint that answers 302, 304, a body-less keep-alive answer, or nothing at all
    When the client requests it
    Then the 302 is reported and its target is never requested, the 304 is the reply, and the connection is closed afterwards and after a timeout
    And plain http to a host name is refused before anything is sent, even when the name resolves to loopback

  @spec:MCP-AUTH-37 @feature:ftAuthorization
  Scenario: A URL the client is sent to needs a scheme, a host and no credentials
    Given URLs without a host or a scheme, with a user name alone or a password alone, and resources with a query
    When the client checks or canonicalizes them
    Then URLs without a host or a scheme and URLs with any credentials are refused
    And a canonical resource keeps its query, and a form field with a space is encoded as %20

  @spec:MCP-AUTH-38
  Scenario: The metadata of an authorization server is read for what it states, and its endpoints are HTTPS
    Given an authorization server metadata document
    When its authorization_endpoint or registration_endpoint is plain http to a remote host, or the registration_endpoint is missing or null
    Then the document is rejected in the first case and offers no registration in the second

  @spec:MCP-AUTH-39
  Scenario: A redirect URI is absolute, without a fragment, and https or loopback
    Given a redirect URI with a fragment, without a host, with another scheme, or plain http to a remote host
    When it is checked, or an authorization request is made with it
    Then it is refused with OAuthSecurityError and no request is made

  @spec:MCP-AUTH-40
  Scenario: An authorization response answers the request only by its exact state, and carries a code
    Given an authorization response
    When its state differs from the request's in one character, or it has no code or an empty one
    Then it is refused

  @spec:MCP-AUTH-41
  Scenario: A token response is kept only when it has an access token, and its lifetime is read exactly
    Given a token response
    When it has no or an empty access_token, an expires_in of zero, at the bound, as digits with leading zeros, or not made of digits
    Then the first is refused, the others are read by their value or refused, and a token inside the skew of its expiry counts as expired

  @spec:MCP-AUTH-42
  Scenario: A registration answer names a client, and an OAuth error answer is reported as such
    Given a registration response or an error answer
    When the response has no or an empty client_id, or the error answer has a description, none, or is not JSON
    Then registration fails, or the error names the status, the code and the description only when given
