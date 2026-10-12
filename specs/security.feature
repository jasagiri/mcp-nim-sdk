Feature: Security properties
  As an application that talks to MCP peers it does not control
  I want the SDK to hold its security properties without my configuration
  So that a hostile peer cannot turn the SDK against me or against another caller

  These Scenarios are the SDK's own requirements, from the security review of
  2026-10-06, not text of an MCP specification, except where one says so.

  Rule: The JSON Schema validator against hostile input and hostile schemas
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

  Rule: Security of the HTTP server transport
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

  @spec:MCP-SEC-HTTP-9
  Scenario: A hook that cannot decide lets nothing through
    Given a transport with an authorization hook that fails with an error
    When a request to the MCP endpoint arrives
    Then the answer is 500, the request does not reach the server, and no session is made

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

  Rule: Security of the outgoing HTTP client
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

  @spec:MCP-SEC-WIRE-10
  Scenario: An icon that is refused after its answer began leaves no connection behind
    Given an icon request that the server answered with a status other than 200
    When the fetch is refused
    Then the client has closed the connection without reading the body

  @spec:MCP-SEC-WIRE-11
  Scenario: A guarded request is plain http for loopback only and follows no redirect unless asked
    Given a request to a host that resolves to an address the policy allows
    When the scheme is http and the address is not loopback
    Then the request is refused before any connection
    And a redirect is returned as the answer unless the caller asked for redirects to be followed

  @spec:MCP-SEC-WIRE-8
  Scenario: An icon is fetched only from an address its server's spelling allows
    Given an icon of a server the user addressed by a name
    When the name resolves to a loopback, private, link-local or reserved address
    Then the fetch is refused unless the user allowed private networks, and link-local and reserved addresses are always refused

  Rule: Credentials and tokens of the authorization client
    As a client that holds a secret or tokens of one authorization server
    I want them sent to that server only, and its answers read without overflow
    So that an MCP server cannot have them delivered to a server of its choosing

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

  @spec:MCP-SEC-AUTH-5
  Scenario: A number in a token response cannot overflow the clock or make a token immortal
    Given a token response whose expires_in is an integer, a float, a string of digits, absent, larger than ten years, or negative or not a number
    When the client parses it
    Then it counts the lifetime from now for the first three, treats the next three as "no expiry given", and refuses the last without reading a token into the store

  Rule: A receiver of tasks and a client keep within bounds a peer cannot move
    As an operator of a receiver of tasks
    I want one peer's choices to be unable to stop or exhaust the receiver
    So that the tasks of every other owner keep working

  Resource limits are the receiver's to set (basic/utilities/tasks, "Resource
  Management": enforce limits on concurrent tasks per requestor, enforce
  maximum ttl durations, document both). They are defaults a user may change,
  and an excess is an explicit error or, for a ttl, an override the answer says.

  @spec:MCP-SEC-TASKS-1
  Scenario: A ttl no receiver could honor does not reach other owners
    Given a requestor that asks for the largest ttl a number can hold
    When another owner uses the store
    Then every operation of that owner works, because the expiry saturates and the ttl is capped

  @spec:MCP-SEC-TASKS-2
  Scenario: The receiver grants at most its maximum ttl and says so
    Given a store with the default maximum ttl of 24 hours
    When a task asks for more, or for the largest ttl
    Then the task is created with the maximum, the answer carries it, and the Tasks extension's store has the same bound

  @spec:MCP-SEC-TASKS-3
  Scenario: A ttl is a non-negative whole number of milliseconds
    Given a task parameter with a ttl
    When it is a float with a whole value it is read as that number, a larger one as the largest
    Then a fraction, a negative number, a string or anything else is invalid params

  @spec:MCP-SEC-TASKS-4
  Scenario: One owner cannot make the store keep without limit
    Given the default limits on active tasks and kept tasks per owner and on the whole store
    When an owner or many owners reach them
    Then the next task is refused with an error until tasks end or expire, other owners are served, and 0 turns a limit off

  @spec:MCP-SEC-TASKS-5
  Scenario: One task's failing cleanup does not leave the others uncleaned
    Given two expired tasks, the work of one of which cannot be stopped
    When any owner uses the store
    Then both are removed and the failure is reported on stderr

  @spec:MCP-SEC-SWEEP-1
  Scenario: A poll interval a peer suggests is kept within bounds
    Given a task of a peer that suggests a poll interval of 0, a negative number, or days
    When a requestor of the core or of the Tasks extension polls it
    Then it waits at least the minimum and at most the maximum, and the caller's default as given when the peer suggests none

  @spec:MCP-SEC-SWEEP-2
  Scenario: State kept per task is released when the task expires
    Given a receiver that keeps state of its own for the tasks it made
    When a task expires without reaching a terminal status
    Then the store's expiry hook is called once for it, a hook that raises does not stop the others, and the server and the Tasks extension release their state of the task

  @spec:MCP-SEC-SWEEP-3
  Scenario: A field of the wrong type in a sampling request is the server's defect
    Given a sampling/createMessage request whose temperature or a priority is not a number
    When the client parses it
    Then it is a protocol error, answered as invalid params, and not read as 0.0

  @spec:MCP-SEC-SWEEP-5
  Scenario: A client does not follow a server's cursors without end
    Given a server that makes up a new cursor for every page of a list
    When the client reads all pages
    Then it stops with a protocol error after the page limit, which a list of that many pages still fits

  @spec:MCP-SEC-WIRE-9
  Scenario: Text of a peer is decoded as base64 only when it has the shape of base64
    Given text a peer chose where base64 is expected: a cursor, the data of a data URI
    When it holds a character outside the base64 alphabet, or padding anywhere but its end
    Then it is refused as malformed before the decoder sees it, whatever compiler built the decoder

  @spec:MCP-SEC-SCHEMA-9
  Scenario: A pattern may hold any character
    Given a pattern with a character above U+007F as a literal, after a backslash, or where the syntax expects an ASCII character
    When it is compiled and matched
    Then the character stands for itself, or the pattern is refused with a RegexError, and nothing else is raised

  @spec:MCP-SEC-SCHEMA-10
  Scenario: A limit is reached only beyond its value
    Given maxDepth, maxChecks, or an item compared for uniqueItems that nests as deep as maxDepth
    When a validation needs exactly that much, and when it needs one more
    Then the first is validated and the second raises SchemaLimitError, and siblings do not add to the depth

  @spec:MCP-SEC-SCHEMA-11
  Scenario: Character classes and the shorthands follow ECMA-262 at their edges
    Given \D, \W and \S, classes with a leading ^, a leading ], escapes, ranges, a trailing hyphen, and malformed classes
    When patterns with them are matched or compiled
    Then each member and each neighbour of a set is told apart, [] matches nothing and [^] anything, and a malformed class is refused with a RegexError

  @spec:MCP-SEC-SCHEMA-12
  Scenario: Quantifiers match as many times as their counts say
    Given {0}, {0,0}, {1,}, {2,3}, a brace that is no quantifier, ??, a repetition that is not closed or runs backwards, and counts above the limit
    When patterns with them are matched or compiled
    Then the number of repetitions at and around each edge is the one ECMA-262 gives, a malformed repetition is a RegexError and a count above the limit is a RegexLimitError

  @spec:MCP-SEC-SCHEMA-13
  Scenario: Alternation, groups, anchors, escapes and lookaheads follow ECMA-262
    Given alternatives, unbalanced parentheses, unsupported group syntax, many groups one after another, a backslash or hex escape at the end of the pattern, \b and \B at the ends of the text, and lookaheads
    When patterns with them are matched or compiled
    Then every alternative is required equally, a pattern that cannot be read is a RegexError whose message names the cause and its position, and a lookahead looks only at the characters after its position

  @spec:MCP-SEC-SCHEMA-14
  Scenario: The limits on a pattern are exact
    Given a pattern whose program is exactly the size limit, a pattern that does exactly the work allowed, and a match that needs exactly the step budget
    When each is compiled or matched
    Then it is accepted, and one instruction, one step more is a RegexLimitError

  @spec:MCP-SEC-SWEEP-6
  Scenario: The inputs that fuzzing found stay handled
    Given the seeds of every fuzzing target and every input kept under tests/fuzz/corpus
    When each is handled by its target
    Then nothing is wrong and no defect is raised

  @spec:MCP-SEC-WIRE-12
  Scenario: An IPv6 block set aside by an RFC is reserved to its last address and not beyond
    Given the NAT64 prefix 64:ff9b::/96 and its local-use sibling 64:ff9b:1::/48, 6to4 2002::/16, IPv4-mapped ::ffff:0:0/96, the discard prefix 100::/64, the protocol assignments 2001::/23, the documentation prefixes 2001:db8::/32 and 3fff::/20, and the link-local prefix fe80::/10
    When an address is classified
    Then an address inside NAT64, 6to4 or IPv4-mapped is judged by the IPv4 address inside it, and one inside a reserved block is reserved
    And an address next to a block but outside it is judged on its own, not as part of the block

  @spec:MCP-SEC-WIRE-13
  Scenario: A host written in an IPv4 notation is read the way inet_aton reads it, and no further
    Given a host of one to four parts, each decimal, hex in either case or octal
    When it is read as an address
    Then each digit has its value in its base, a digit its base does not have makes the text a name, and an empty part makes it a name
    And the last part must fit in the bytes left for it, so that 127.16777215 is loopback and 127.16777216 and 4294967296 are names

  @spec:MCP-SEC-WIRE-14
  Scenario: A destination is loopback-only exactly when every address of the host is loopback
    Given a host that is an address, or a name that resolves to several
    When a destination is chosen under a policy that allows them
    Then it is loopback-only if all of its addresses are loopback, and not if any is not
    And the host written as an address is answered by the system resolver with that address

  @spec:MCP-SEC-WIRE-15
  Scenario: The request is written as HTTP/1.1 asks
    Given a request to a URL with or without a port, a path and a query, and headers the caller chose
    When it is sent
    Then the request line names the path and query, or / when there is none, and Host names the host and the port only when the URL has one
    And Content-Length is sent for a POST and for any request with a body, and for no other
    And a header name is a token (digits allowed, never empty), and a URL with a space or a control character is refused before a connection is made
    And a URL without a port connects to the port of its scheme, and the host of the URL is the one connected to unless the caller chose an address

  @spec:MCP-SEC-WIRE-16
  Scenario: The response head is read as HTTP/1.1 asks
    Given an answer from a server
    When its status line lacks a reason phrase, does not start with HTTP/, or has no status, or its head is empty, or a header line has no name, or its Content-Length is negative
    Then it is taken, or refused as not HTTP or as a bad Content-Length, and a line without a name is no header
    And the answer to HEAD, and any 1xx, 204 or 304, has no body and is finished at once
    And a request that fails on what the server sent closes its connection, as does one that gets no answer within its header timeout

  @spec:MCP-SEC-WIRE-17
  Scenario: A redirect is followed only within the origin and its connection is closed
    Given an answer that redirects
    When the location is on the same origin, on another host name with the same port, or under another scheme
    Then only the first is followed, the others are refused without anything sent there
    And the connection that gave the redirect is closed in every case

  @spec:MCP-SEC-WIRE-18
  Scenario: Limits on a response, and the ends of a body
    Given a server answering a request
    When the head is exactly as long as the limit, or one byte over; a chunk size line is 64 bytes, or 65; a body is exactly or one byte over the size the caller allows
    Then the first of each pair is accepted and the second refused, and a body that outgrows its limit has its connection closed
    And a chunked body ends at its blank line after the last chunk (and any trailer), not before, and a chunk size line that arrives before its data does not end the body
    And a body cut short fails, and the response is finished; a connect timeout of 0 means no limit

  @spec:MCP-SEC-WIRE-19
  Scenario: A response closed while a read waits ends the read without an error
    Given a read waiting for the head or for the body of a response
    When the response is closed by its holder
    Then the read ends as abandoned (the head) or with the end of the body, and no operating system error is reported
    And a read started on a response already closed ends the same way

  @spec:MCP-SEC-WIRE-20
  Scenario: A connection that does not become a response is closed
    Given a request that fails before there is a response
    When the TLS certificate is refused, https is asked of a build without TLS, or a handshake finishes after its connect timeout
    Then the client closes the connection, so that no descriptor is left open

  @spec:MCP-SEC-WIRE-21
  Scenario: An IPv6 address outside the global unicast block is reserved unless another class claims it
    Given the global unicast block 2000::/3
    When an IPv6 address outside it, such as fec0::1, ::ff:7f00:1 or 100:0:0:1::, is classified and no other class (loopback, link-local, unique local, IPv4-embedding, multicast) claims it
    Then it is reserved, and so is refused in every notation, whatever the policy allows
    And an address inside 2000::/3 that no block sets aside is public, to its first and last address

  @spec:MCP-SEC-HTTP-8
  Scenario: A failure inside the HTTP transport is logged and not told to the peer
    Given a session whose end callback raises
    When the client sends DELETE
    Then the answer is a bare 500 with no body
    And the log holds one line naming the failure
    And the server goes on answering
