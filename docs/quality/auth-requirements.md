# Authorization requirements by protocol version

Source: `docs/specification/<version>/basic/authorization.mdx` (2026-07-28:
`basic/authorization/{index,authorization-server-discovery,client-registration,security-considerations}.mdx`)
and `changelog.mdx`, at upstream commit `75db1e987cbbba6d170315dc99d0dfc440754aef`.

Authorization is OPTIONAL in every version (HTTP transports SHOULD follow it,
stdio SHOULD NOT). The `2024-11-05` specification has no authorization.

Legend: **M** MUST, **S** SHOULD, **m** MAY, `-` not in that version's text,
**=** unchanged from the column to the left. "Impl" is where this SDK does it
(`C` client, `R` resource server). An authorization server is out of scope: the
SDK implements the two roles an MCP implementation plays.

## Discovery

| ID | Requirement | 03-26 | 06-18 | 11-25 | 07-28 | Impl |
|---|---|---|---|---|---|---|
| D1 | Client acts on `401` (starts authorization) | M | M | M | M | C |
| D2 | Client parses `WWW-Authenticate` | - | M | M | M | C |
| D3 | Server sends `WWW-Authenticate` with `resource_metadata` on 401 | - | M | M (or D4b) | M (or D4b) | R |
| D4a | Server implements Protected Resource Metadata (RFC 9728), `authorization_servers` has at least one entry | - | M | M | M | R |
| D4b | Server may serve PRM at the well-known URI instead of the header (path-specific, then root) | - | - | M (one of header / well-known) | = | R |
| D5 | Client uses PRM to find the authorization server | - | M | M | M | C |
| D6 | Client falls back to the well-known PRM URIs when the header has no `resource_metadata` (path-specific first, then root) | - | - | M | M | C |
| D7 | Client picks the authorization server among several (RFC 9728 7.6) | - | M (client's choice) | = | = | C (callback, default first) |
| D8 | PRM `resource` must match the resource the client asked for (RFC 9728 3.3, "Validate RS metadata" in the diagram) | - | implied | implied | implied | C |
| D9 | AS metadata: RFC 8414 | M | M | M (or OIDC) | M (or OIDC) | C |
| D10 | AS base URL is the MCP server URL without its path; metadata at `<base>/.well-known/oauth-authorization-server` | M | - | - | - | C |
| D11 | If metadata is missing (404): default endpoints `/authorize`, `/token`, `/register` on the base URL | M | - | - | - | C |
| D12 | AS metadata URL built from the issuer (RFC 8414 path insertion) | - | M | M | M | C |
| D13 | Try OAuth 2.0 AS metadata, then OpenID Connect Discovery (path insertion, then path appending for issuers with a path) | - | - | M | M | C |
| D14 | Client sends `MCP-Protocol-Version` during metadata discovery | S | - | - | - | C |
| D15 | Metadata `issuer` is identical to the issuer used to build the URL, else the metadata is not used | - | implied (RFC 8414 3.3) | implied | M | C (checked from 06-18) |
| D16 | Servers without AS metadata support default endpoints | M | - | - | - | out of scope (AS role) |

## Authorization flow

| ID | Requirement | 03-26 | 06-18 | 11-25 | 07-28 | Impl |
|---|---|---|---|---|---|---|
| F1 | OAuth 2.1 authorization code grant, public clients | M | M | M | M | C |
| F2 | PKCE for every client | M | M | M | M | C |
| F3 | Verify AS PKCE support: `code_challenge_methods_supported` present, else refuse | - | - | M | M | C |
| F4 | `S256` challenge method | (implied) | (implied) | M | M | C |
| F5 | `resource` parameter (RFC 8707) in authorization and token requests, canonical URI of the MCP server | - | M | M | M | C |
| F6 | `resource` sent whether or not the AS supports it | - | M | M | M | C |
| F7 | `state` used and verified; a response without or with another `state` is discarded | S | S | S | S | C (always) |
| F8 | Redirect URI is `localhost` or HTTPS; exact match against the registered one | M | M | M | M | C |
| F9 | AS endpoints served over HTTPS | M | M | M | M | C (loopback http allowed, see below) |
| F10 | Record the expected `issuer` before redirecting the user agent | - | - | - | M | C |
| F11 | Validate `iss` in the authorization response (RFC 9207) before redeeming the code: supported=true and absent: reject; present: exact string comparison; supported=false/absent and absent: proceed | - | - | - | M | C |
| F12 | `iss` checked on error responses too; on mismatch `error*` is neither acted on nor shown | - | - | - | M | C |
| F13 | AS includes `iss`, advertises `authorization_response_iss_parameter_supported` | - | - | - | S | out of scope (AS role) |

## Client registration

| ID | Requirement | 03-26 | 06-18 | 11-25 | 07-28 | Impl |
|---|---|---|---|---|---|---|
| R1 | Dynamic Client Registration (RFC 7591) | S | S | m | m (deprecated) | C |
| R2 | Without DCR: hardcoded credentials or user entry | M (one of) | M (one of) | = (pre-registration S) | = | C (pre-registration) |
| R3 | Priority: pre-registered, then CIMD, then DCR, then ask the user | - | - | S | S | C |
| R4 | Client ID Metadata Documents: `client_id` is an https URL with a path; the document has `client_id`, `client_name`, `redirect_uris`; `client_id` equals the document URL | - | - | S (M if supported) | = | C (validates the client_id URL and the document it is given; hosting is the application's job) |
| R5 | Use CIMD only when AS metadata has `client_id_metadata_document_supported` | - | - | S | S | C |
| R6 | DCR sends `application_type` (`native` / `web`) | - | - | - | M | C |
| R7 | Credentials keyed by `issuer`; never reused with another AS; re-register when the AS changes; pre-registered credentials that no longer match: surface an error | - | - | - | M (S for the error) | C |
| R8 | Separate registration state and tokens per AS | - | - | - | M | C |

## Tokens and scopes

| ID | Requirement | 03-26 | 06-18 | 11-25 | 07-28 | Impl |
|---|---|---|---|---|---|---|
| T1 | `Authorization: Bearer` on every HTTP request, never in the query string | M | M | M | M | C |
| T2 | Secure token storage | M | M | M | M | C (store is the application's; default is memory only) |
| T3 | Client never sends a token that its server's AS did not issue | - | M | M | M | C (tokens keyed by issuer and resource) |
| T4 | Refresh tokens (rotation by the AS) | S | M (AS, public clients) | = | = | C |
| T5 | Refresh tokens kept confidential; `refresh_token` in `grant_types`; may add `offline_access`; do not assume one is issued | - | - | - | M / S / m / M | C |
| T6 | Scope for the first request: `scope` of the challenge, else `scopes_supported`, else none | - | - | S | S | C |
| T7 | Challenge scopes are authoritative; no assumed relation to `scopes_supported` | - | - | M | M | C |
| T8 | Step-up on 403 `insufficient_scope` (retry limit; no endless loop) | - | - | S | S | C |
| T9 | Re-authorize with the union of previously requested and challenged scopes | - | - | - | S | C |
| T10 | Client acting for itself (`client_credentials`) may skip step-up | - | - | m | m | not applicable: the extension is out of scope |

## Resource server

| ID | Requirement | 03-26 | 06-18 | 11-25 | 07-28 | Impl |
|---|---|---|---|---|---|---|
| S1 | Validate the access token (OAuth 2.1 5.2); invalid or expired: 401 | M | M | M | M | R (verifier callback) |
| S2 | Token issued for this server (audience, RFC 8707 2): reject others | - | M | M | M | R (verifier callback's duty; documented as MUST) |
| S3 | No token passthrough upstream | - | M | M | M | documented on the verifier |
| S4 | 403 for insufficient scope, with `error="insufficient_scope"`, `scope`, `resource_metadata` | (403 only) | (403 only) | S | S | R |
| S5 | `scope` in the 401 challenge | - | - | S | S | R |
| S6 | Whole required scope set in one challenge | - | - | - | S | R (callback returns the set) |
| S7 | Scope hierarchies when checking sufficiency | - | - | - | M | verifier callback's duty |
| S8 | `offline_access` not in `scope` / `scopes_supported` of the resource | - | - | - | S | not enforced (documented) |
| S9 | 400 for malformed authorization requests | M | M | M | M | AS role |

## Decisions that are the SDK's own

- The protocol version of an authorization exchange is the one the client is
  configured to speak (`AuthConfig.version`, default `DefaultProtocolVersion`);
  a 401 arrives before `initialize` has negotiated anything.
- Plain `http` is accepted only for `localhost`, `127.0.0.1` and `::1`
  (`FetchPolicy.allowLoopback`), because the specification's tests and local
  development servers use it. Every other URL the client fetches or
  redirects to has to be `https`.
- A literal IP address in a URL that came from the network (a
  `resource_metadata` URL, a metadata endpoint) is refused when it is
  link-local, and when it is in a private range unless
  `FetchPolicy.allowPrivateNetworks` is set. Host names are not resolved, so
  a name that resolves to such an address is not caught.
- Bodies fetched for metadata are capped (`FetchPolicy.maxBodySize`), and
  redirects are not followed.
- Extensions (OAuth Client Credentials, Enterprise-Managed Authorization) are
  not implemented.
