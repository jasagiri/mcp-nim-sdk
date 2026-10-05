# Authorization extensions (ext-auth)

Sources, read in full:

- `modelcontextprotocol/ext-auth` at `fb374c7db2b34f18ca9183882e0beecdf661892b`:
  `README.md`, `specification/draft/oauth-client-credentials.mdx` (draft),
  `specification/stable/enterprise-managed-authorization.mdx` (stable).
  Nothing else is in the repository.
- `docs/extensions/auth/{overview,oauth-client-credentials,enterprise-managed-authorization}.mdx`
  and `docs/extensions/overview.mdx` of `modelcontextprotocol/modelcontextprotocol` at
  `75db1e987cbbba6d170315dc99d0dfc440754aef`: the extension identifiers and how they are
  declared. The ext-auth texts themselves define neither.
- `draft-ietf-oauth-identity-assertion-authz-grant-04` (Internet-Draft, May 2026): the
  processing rules the enterprise-managed text points to (sections 3.1, 4.3, 4.4, 7).

Implementation: `src/ext/auth_client_credentials.nim`, `src/ext/auth_enterprise_managed.nim`,
`src/ext/auth_shared.nim`; the parts that do not know MCP are in `src/auth/oauth/`
(`jwt`, `grants`, `metadata_fields`). Specifications: `specs/ext_auth.feature`
(`MCP-EXT-AUTH-1` to `-14`).

Both extensions are optional and never active by default (the extension overview page:
"Extensions are always disabled by default and require explicit opt-in from the developer").
Here that means: nothing happens at import. The application builds the auth object and gives
it to `StreamableHttpTransport.auth` (or calls `enable...`, which also declares the extension).

## The two extensions

| | OAuth Client Credentials | Enterprise-Managed Authorization |
|---|---|---|
| Identifier | `io.modelcontextprotocol/oauth-client-credentials` | `io.modelcontextprotocol/enterprise-managed-authorization` |
| Status in ext-auth | draft (`specification/draft/`) | stable (`specification/stable/`) |
| MCP versions | The text says "Protocol Revision: draft"; it builds on the core authorization (Protected Resource Metadata: 2025-06-18 and later). The `extensions` declaration exists in 2026-07-28 only. | Same. The text names the 2025-11-25 Client ID Metadata Documents. |
| Declared where | The extension page: client `_meta["io.modelcontextprotocol/clientCapabilities"].extensions`, server `capabilities.extensions` (optional, "recommended for discoverability"), both with `{}` settings. | Same for the client; the server "declares the extension in your server's authorization metadata", which the text does not make concrete (see open points). |
| Detected by | Authorization server metadata: `token_endpoint_auth_methods_supported` (MUST include `private_key_jwt` or `client_secret_basic`), `token_endpoint_auth_signing_alg_values_supported` (MUST for JWT). | Authorization server metadata: `authorization_grant_profiles_supported` includes `urn:ietf:params:oauth:grant-profile:id-jag` (spec 6), plus `grant_types_supported` includes jwt-bearer (draft 7.2). |
| Wire | `grant_type=client_credentials` at the token endpoint, `resource`, `scope`; client authenticates by `private_key_jwt` (RFC 7523 2.2, RECOMMENDED) or a client secret. No dynamic client registration. | Token exchange at the IdP (`requested_token_type=...:id-jag`, `audience` = the authorization server's issuer, `resource` optional), then `grant_type=...:jwt-bearer` with `assertion` = the ID-JAG at the authorization server. |

## Obligations

Legend: **C** MCP client (implemented), **R** MCP server as resource server, **A** authorization
server or IdP (out of scope: the SDK implements the two roles an MCP implementation plays; see
auth-requirements.md). "Impl" says where.

### OAuth Client Credentials

| ID | Requirement (text) | Role | Impl |
|---|---|---|---|
| CC1 | Conform to the baseline authorization requirements as well | C | the 401, PRM and metadata discovery reuse `auth/oauth/discovery`, `metadata`, `challenge` |
| CC2 | HTTP-based transports | C | `StreamableHttpTransport.auth` |
| CC3 | Authenticate with JWT (RFC 7523 2.2) or a client secret | C | `ClientAuthentication`, `grants.nim` |
| CC4 | AS metadata MUST list `private_key_jwt` or `client_secret_basic` in `token_endpoint_auth_methods_supported`, and the signing algorithms for JWT | C checks it, A provides | `authenticationFor`: nothing is sent to a server that does not |
| CC5 | `resource` and `scope` in the request; `client_id` omitted for JWT (RFC 7523 3) | C | `clientCredentialsGrant`, `authenticate` |
| CC6 | Pre-registered credentials; no DCR | C | config takes `clientId` and a credential; no registration code |
| CC7 | Follow OAuth 2.1 security practices; protect credentials | C | no secret in an error message; token endpoint https (loopback http), no redirects, bounded response (`fetch.nim`) |
| CC8 | Extension `extensions` declaration | C, R (optional) | `declareClientCredentials`, `advertiseClientCredentials` |
| CC9 | Validate the access token (signature, claims), check scopes | R | existing `auth/resource_server` (`TokenVerifier`); nothing new |

### Enterprise-Managed Authorization

| ID | Requirement (text) | Role | Impl |
|---|---|---|---|
| EM1 | Token exchange at the IdP with `audience` = the authorization server's issuer, `resource` (optional) = the MCP server's resource identifier | C | `obtainGrant` |
| EM2 | IdP client authentication when the IdP required it for SSO | C | `idpClientAuthentication` (secret, `private_key_jwt`, or `client_id` only) |
| EM3 | `subject_token` is the ID token, a SAML assertion or a refresh token, with its `subject_token_type` | C | `IdentityAssertionKind` |
| EM4 | The ID-JAG `resource` claim contains the MCP server if present | A issues; C checks before sending | `checkIdentityAssertionGrant` |
| EM5 | Present the ID-JAG with `grant_type=jwt-bearer`, `assertion`; authenticate with the credentials registered at the authorization server, or use a Client ID Metadata Document URL as `client_id` (optionally `private_key_jwt`) | C | `jwtBearerGrant`, `resourceClientAuthentication` (`publicClient(url)`) |
| EM6 | The access token MUST be audience-restricted to the MCP server named by the ID-JAG `resource` claim | A | out of scope; the test authorization server checks it; the MCP server's `TokenVerifier` checks audience |
| EM7 | Discovery: `authorization_grant_profiles_supported` | C | `requireProfile` (no ID-JAG is sent to a server that does not list it) |
| EM8 | Draft 3.1/4.4.1: `typ` `oauth-id-jag+jwt`, `aud` is the authorization server (string or one-element array), `client_id` is the authenticating client, `exp` in the future | A validates (incl. signature); C checks the same claims first | `checkIdentityAssertionGrant` (signature NOT checked) |
| EM9 | Draft 4.4.3: no refresh token from the authorization server; the client may present the ID-JAG again; if it expired, ask the IdP again with the identity assertion | C | `acquire` drops a refresh token, `obtainGrant` caches the ID-JAG until `exp` |
| EM10 | Single sign-on (OIDC / SAML) to the client | C | the application's (`identityAssertion` callback) |
| EM11 | Extension `extensions` declaration | C, R (optional) | `declareEnterpriseManaged`, `advertiseEnterpriseManaged` |

## SDK decisions where the text is silent or two texts differ

- **Declaration vs. activation.** The ext-auth texts never mention the `extensions` capability.
  The extension pages say a client "declares support" there. The authorization itself happens
  before any MCP message (on the 401), so it does not depend on the declaration. The two are
  separate calls (`asHttpAuth` for the behavior, `declare...` for the capability); `enable...`
  does both. A client does not wait for the server to advertise the extension.
- **JWT client credentials: two descriptions.** The ext-auth text (normative) uses
  `grant_type=client_credentials` with `client_assertion` (RFC 7523 2.2). The extension page of the
  specification repository draws `grant_type=...:jwt-bearer` with `assertion` for the same method.
  The SDK follows the ext-auth text.
- **Client secret: header or body.** The text says the secret is "transmitted in the request
  content" and shows `client_id`/`client_secret` in the body, but requires the metadata to list
  `client_secret_basic`. The SDK sends HTTP Basic when the server lists `client_secret_basic`, the
  body when it lists only `client_secret_post`, and refuses a server that lists neither (SDK's
  choice, in the safe direction).
- **Assertion audience.** The text does not say what `aud` of the client assertion is; the extension
  page says the token endpoint URL. Default here: the issuer identifier; `aaTokenEndpoint` selects
  the URL.
- **`grant_types_supported` for client credentials** is not required by the text. If a server
  publishes it without `client_credentials`, the client does not send credentials (SDK's addition).
- **ID-JAG claim checks by the client** (`iss` equals the IdP's issuer exactly, `client_id`, `resource`)
  are the SDK's addition: the draft puts these checks on the authorization server. They stop the
  client from sending the user's identity assertion grant to the wrong server or with the wrong
  binding.
- **No fallback.** A client with enterprise-managed authorization enabled does not fall back to the
  interactive flow when the server lacks the profile; it reports the reason.
- **`resource` at the jwt-bearer request.** The text's example has none (the ID-JAG carries it);
  the SDK sends none.

## Open points (not settled by the texts)

1. The client-credentials text is a draft; the identifiers and `extensions` declaration come from
   the documentation pages, not the ext-auth specification.
2. How an MCP server "declares the extension in its authorization metadata" (enterprise-managed,
   server step 1) is not defined. The SDK advertises it in `capabilities.extensions` and relies on the
   authorization server's `authorization_grant_profiles_supported` for the rest.
3. SAML to refresh token exchange (draft 4.5) is not wrapped: an application can call
   `exchangeToken` with `requestedTokenType = refresh_token`, then hand the refresh token over as
   `iakRefreshToken`.
4. `actor_token`, Rich Authorization Requests (`authorization_details`), DPoP / sender-constrained
   tokens (draft 9.8) are not implemented.
5. Signing: the SDK has no RSA / ECDSA. `JwtSigner` takes the application's function. The tests use
   HMAC-SHA256 on both sides as a stand-in.
6. No interoperability run against an official SDK's implementation of these extensions was done.
