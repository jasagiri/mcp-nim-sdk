## Elicitation from the server's side: ask the user for input through the
## client (elicitation/create, 2025-06-18 to 2025-11-25). Later versions carry
## elicitation in another way; the payload rules are in
## `protocol/elicitation`.

import std/[asyncdispatch, json, options]
import ../protocol/types
import ../protocol/lifecycle
import ../protocol/features
import ../protocol/elicitation
import ./server

export elicitation

proc requireElicitation(server: McpServer, session: string, mode: ElicitMode) =
  ## Raises McpCapabilityError unless the client on `session` can be asked in
  ## `mode`: it has handshaken, speaks a version with elicitation, and declared
  ## the mode.
  let known = server.session(session)
  if known.state != mlsOperational or known.negotiatedVersion.isNone:
    raise newException(McpCapabilityError,
      "no initialized client on session '" & session & "' to elicit from")
  let version = known.negotiatedVersion.get
  if not version.has(ftElicitation):
    raise newException(McpCapabilityError,
      "elicitation/create: protocol version " & $version & " has no elicitation")
  let declared = known.clientCapabilities.get(McpClientCapabilities()).elicitation
  if declared.isNone or not declared.get.modeSupported(mode):
    raise newException(McpCapabilityError,
      "the client on session '" & session & "' did not declare the elicitation " &
      $mode & " mode")

proc elicit*(server: McpServer, session: string, message: string,
             requestedSchema: JsonNode,
             relatedRequestId = ""): Future[McpElicitResult] {.async.} =
  ## Ask the user of the client on `session` to fill in a form described by
  ## `requestedSchema` (a flat object of primitive properties). Raises
  ## McpCapabilityError when the client cannot be asked, McpPayloadError when
  ## the schema breaks the rules or the answer does not match it,
  ## McpRemoteError when the client answers with an error.
  server.requireElicitation(session, emForm)
  let version = server.session(session).negotiatedVersion.get
  let params = formElicitationParams(message, requestedSchema, version)
  let response = await server.request(session, "elicitation/create", params,
                                      relatedRequestId)
  return parseElicitationResult(resultOf(response, "elicitation/create"), params)

proc elicit*(ctx: McpRequestContext, message: string,
             requestedSchema: JsonNode): Future[McpElicitResult] =
  ctx.server.elicit(ctx.session, message, requestedSchema, ctx.requestId)
