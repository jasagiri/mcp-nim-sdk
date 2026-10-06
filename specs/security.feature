Feature: The JSON Schema validator against hostile input and hostile schemas
  As an operator whose server checks tool arguments, and a client that checks
  results against a schema the server supplied
  I want the validator to stay within bounded stack, time and memory
  So that one request or one schema cannot take the process down

  @spec:MCP-SEC-SCHEMA-1
  Scenario: A plain pattern is checked against text of any length the transport allows
    Given a pattern such as ^[a-z]+$ and 4 MiB of text
    When the text is matched
    Then the answer is given and the process neither crashes nor exhausts its stack

  @spec:MCP-SEC-SCHEMA-2
  Scenario: A pattern that backtracks catastrophically is answered in time proportional to the text
    Given patterns such as (a|a)*$, (a+)+$ and (a|aa)+$ and 100000 characters of text
    When the text is matched
    Then each answer is the one the pattern means, and a match that exceeds its step budget raises a limit error instead of a verdict

  @spec:MCP-SEC-SCHEMA-3
  Scenario: A pattern that asks for an enormous program is refused
    Given a pattern with a huge repetition count, nested repetitions, too many characters or too many nested groups
    When it is compiled
    Then a limit error is raised, and a caller can raise the limit

  @spec:MCP-SEC-SCHEMA-4
  Scenario: A $ref that leads back to itself without reading further into the instance is an invalid schema
    Given schemas such as {"$ref": "#"}, two $refs that point at each other, or a $ref cycle through allOf
    When an instance is validated
    Then InvalidSchemaError is raised, while a recursive schema that reads deeper into the instance (a tree) is still validated

  @spec:MCP-SEC-SCHEMA-5
  Scenario: Validation stops at its depth, work and regular expression limits instead of exhausting the process
    Given an instance or a schema nested beyond the depth limit, $refs that double at every level, or matches that add up above the regex budget
    When an instance is validated
    Then SchemaLimitError (an InvalidSchemaError) is raised, never a verdict, and the caller can change the limits

  @spec:MCP-SEC-SCHEMA-6
  Scenario: A length or size limit written as a number with no fractional part is read as that integer
    Given minLength, maxLength, minItems, maxItems, minProperties, maxProperties, minContains or maxContains with the value 5.0
    When an instance is validated
    Then the limit applies as 5 does, and a value that is negative, fractional or not a number is an invalid schema, never read as 0

  @spec:MCP-SEC-SCHEMA-7
  Scenario: uniqueItems takes time proportional to the items and follows JSON equality
    Given an array of 100000 distinct objects, and arrays of values that are or only look equal such as 1 and 1.0, objects with keys in another order, [1, 2] and [2, 1], or 9007199254740993 and 9007199254740992
    When uniqueItems is checked
    Then the answer is immediate, equal values are reported with the index of the first copy, and values that differ are not

  @spec:MCP-SEC-SCHEMA-8
  Scenario: A malformed keyword is reported, never skipped, and no schema makes the validator raise something else
    Given dependentRequired or draft-07 dependencies that do not hold lists of names, a $ref index that overflows or is out of range, or a multipleOf whose quotient a double cannot hold
    When an instance is validated
    Then InvalidSchemaError (or SchemaLimitError for the quotient) is raised, and the instance is not reported as conforming
Feature: Security of the HTTP server transport
  As an operator who puts an MCP server behind authorization
  I want every endpoint of the transport to be protected, and a client to be bound to its own session
  So that one caller cannot read, answer, cancel or starve another's

  Specification: Authorization (2025-03-26 and later, basic/authorization:
  "Token Requirements": every HTTP request from client to server MUST carry
  the token, whether or not they are part of the same logical session) and
  Streamable HTTP, "Security Warning" (2025-11-25, 2026-07-28). Findings:
  build/SECURITY_FINDINGS.md C1, M1, M2, M6, L5, L6.

  @spec:MCP-SEC-HTTP-1
  Scenario: A transport with authorization protects every MCP endpoint
    Given a transport with a token verifier
    When a request without a token arrives at the MCP path, at the HTTP+SSE event stream path or at the HTTP+SSE messages path
    Then each is answered 401 and nothing reaches the MCP server
    And a request with a good token reaches the server as that principal
    And a fixed document and the authorization metadata are still served without a token

  @spec:MCP-SEC-HTTP-2
  Scenario: A session belongs to the principal that made it
    Given a transport with a token verifier and a session that alice made
    When bob, with a good token of his own, uses its Mcp-Session-Id to post, open the GET stream or DELETE, or posts to alice's HTTP+SSE endpoint
    Then the answer is 404 and alice's session is untouched
    And alice herself is served as before

  @spec:MCP-SEC-HTTP-6
  Scenario: A cancellation cancels only the sender's own request
    Given clients with requests in progress on a transport, some of them 2026-07-28 and some in sessions
    When a client posts notifications/cancelled naming the id it chose, the id of another client's request, or the id the transport made for one
    Then a session's request named by the session's own id is cancelled
    And no other client's request is cancelled, whatever id is named
    And a 2026-07-28 request is cancelled by its client closing the connection, which the notification cannot do

  @spec:MCP-SEC-HTTP-3
  Scenario: One caller cannot use up the transport's resources
    Given a transport with small limits
    When initialize requests fill the session limit, one address holds its share of sessions, a batch is too long, or requests or messages pile up
    Then the oldest session that was never used again is dropped for a new client, and a session in use is not
    And an address at its limit loses only its own unused sessions or is refused with 503
    And a batch over the limit is answered 400, and work over the limit 503 with Retry-After

  @spec:MCP-SEC-HTTP-5
  Scenario: A request must be addressed to this server
    Given a transport bound to a loopback address
    When a request names a host that is not a loopback name nor in allowedHosts, as a rebound DNS name does, on any endpoint including a GET without Origin
    Then the answer is 403 and nothing is created or delivered
    And loopback names, with or without a port, and the listed hosts are served
    And a transport bound elsewhere checks Host only when hosts are listed

  @spec:MCP-SEC-HTTP-7
  Scenario: What a peer chose is made harmless before it is written to a diagnostic
    Given text a peer chose: a request id, a method name, a reason, an error message, a whole message
    When the server or a transport writes it to stderr
    Then line breaks, escape and other control characters, line separators and bidirectional overrides are shown as escapes
    And invalid UTF-8 bytes are shown as escapes
    And one message is cut to a bounded length, with the number of bytes left out
Feature: Security of the outgoing HTTP client
  As someone who connects an MCP client to servers across a network
  I want the client to talk only to the server it was pointed at
  So that a stranger on the path or a server's own redirection cannot take the connection over

  Not a rule of the MCP specification: these follow the security guidance of
  basic/authorization and basic/transports (HTTPS, no credentials to other
  hosts) and RFC 6125 (the certificate names the host that was asked for).

  @spec:MCP-SEC-WIRE-1
  Scenario: A TLS server whose certificate names another host is refused
    Given a TLS server with a certificate signed by a trusted CA
    When the client requests a URL whose host is not in that certificate
    Then the request fails before any HTTP is sent
    And the same certificate is accepted for a URL whose host it names, as a DNS name or an IP address

  @spec:MCP-SEC-WIRE-2
  Scenario: Line breaks and control characters cannot travel in a request or be read from a response head
    Given a client about to send a request
    When the URL or a header name or value contains a CR, LF or NUL, or a header name is not a token
    Then the request is refused before a connection is made
    And a response head with a bare LF or CR, a NUL or another control character inside a line is refused

  @spec:MCP-SEC-WIRE-3
  Scenario: What a server sends is bounded in size and in time
    Given a client reading an event stream
    When a line or an event grows past its limit without a line break or a blank line
    Then the stream is ended with an error before the line or event is complete
    And a request on a connection that gets no TLS handshake or no response head within its timeout fails
    And with no header timeout the answer to a request is waited for as long as its caller waits

  @spec:MCP-SEC-WIRE-4
  Scenario: A URL is judged by the address its host stands for, in any notation
    Given a URL that came from the network
    When its host is `2130706433`, `0x7f.1`, `::ffff:7f00:1`, `0:0:0:0:0:0:0:1`, `::` or `0.0.0.0`
    Then it is classified as loopback or reserved, like `127.0.0.1`
    And a link-local address (a cloud metadata service) or a reserved one is refused in every notation, whatever the policy allows

  @spec:MCP-SEC-WIRE-5
  Scenario: A host name is judged by what it resolves to, and the connection goes to that address
    Given an OAuth metadata, registration or token request, a Server Card or AI Catalog fetch
    When the host name resolves to an address the policy does not allow, or to several of which one is not allowed, or does not resolve
    Then the request is refused before anything is connected
    And a request that is allowed connects to the address that was judged, not to the name again

  @spec:MCP-SEC-WIRE-6
  Scenario: Loopback is reachable only for a server the user chose
    Given a client the user pointed at an MCP server
    When the metadata of a server that is not on loopback names a loopback URL
    Then the client refuses it
    And when the user's own server is on loopback, loopback URLs stay allowed (local development)

  @spec:MCP-SEC-WIRE-7
  Scenario: An icon fetch that gives up leaves no connection behind
    Given an icon request that has timed out
    When the server answers after the timeout
    Then the client closes that connection

  @spec:MCP-SEC-WIRE-8
  Scenario: An icon is fetched only from an address its server's spelling allows
    Given an icon of a server the user addressed by a name
    When the name resolves to a loopback, private, link-local or reserved address
    Then the fetch is refused unless the user allowed private networks, and link-local and reserved addresses are always refused
Feature: Security properties
  As an application that connects to MCP servers it does not control
  I want the SDK to hold its security properties without my configuration
  So that a hostile peer cannot turn the SDK against me

  Source: the security review of 2026-10-06 (build/SECURITY_FINDINGS.md). These Scenarios are
  the SDK's own requirements, not text of an MCP specification, except where one says so.

  @spec:MCP-SEC-AUTH-1
  Scenario: A client secret is configured for one authorization server and sent to no other
    Given a pre-registered client with a secret, and an MCP server that names an authorization server of its own
    When the client meets a 401 from that MCP server
    Then the client refuses before anything but metadata is requested from that server, says which issuer was expected and which was named, and does not print the secret
    And a client secret that does not name its issuer is refused when the client is made, in every protocol version

  @spec:MCP-SEC-AUTH-2
  Scenario: Tokens and credentials go back only to the authorization server that issued them
    Given tokens of one authorization server and a later challenge that met another and failed
    When the tokens have expired
    Then the refresh token and the client's credentials are not sent to the other server
