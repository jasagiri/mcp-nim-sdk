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
  if mode == emUrl and not version.has(ftUrlElicitation):
    raise newException(McpCapabilityError,
      "elicitation/create: protocol version " & $version & " has no URL mode")
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

proc elicitUrl*(server: McpServer, session: string, message, elicitationId, url: string,
                relatedRequestId = ""): Future[McpElicitResult] {.async.} =
  ## Ask the user of the client on `session` to open `url` (2025-11-25
  ## onward). The answer says whether the user agreed to go there; it does
  ## not say that the interaction is done, so the server learns that out of
  ## band and may then call `notifyElicitationComplete`. `elicitationId` is
  ## unique within this server and opaque to the client. Raises like `elicit`.
  server.requireElicitation(session, emUrl)
  let version = server.session(session).negotiatedVersion.get
  let params = urlElicitationParams(message, elicitationId, url, version)
  let response = await server.request(session, "elicitation/create", params,
                                      relatedRequestId)
  return parseElicitationResult(resultOf(response, "elicitation/create"), params)

proc elicitUrl*(ctx: McpRequestContext, message, elicitationId, url: string): Future[McpElicitResult] =
  ctx.server.elicitUrl(ctx.session, message, elicitationId, url, ctx.requestId)

proc notifyElicitationComplete*(server: McpServer, session: string,
                                elicitationId: string): Future[void] {.async.} =
  ## Tell the client on `session`, which must be the one that was asked, that
  ## the out-of-band interaction of `elicitationId` is complete. The server
  ## does not track which client was given which id: pass the session the
  ## request or the -32042 error went to.
  server.requireElicitation(session, emUrl)
  let version = server.session(session).negotiatedVersion.get
  await server.sendNotification("notifications/elicitation/complete",
    elicitationCompleteParams(elicitationId, version), session)

proc urlElicitationRequired*(version: McpProtocolVersion, elicitations: seq[JsonNode],
                             message = "This request requires more information."
                             ): ref McpRequestError =
  ## The error a handler raises when its request cannot go on until the user
  ## has done the URL mode elicitations in `elicitations` (build them with
  ## `urlElicitationParams`). Only 2025-11-25 has it; raises McpPayloadError
  ## for another version or for entries that are not URL requests.
  newRequestError(UrlElicitationRequiredCode, message,
                  urlElicitationRequiredData(elicitations, version))

proc urlElicitationRequired*(ctx: McpRequestContext, elicitations: seq[JsonNode],
                             message = "This request requires more information."
                             ): ref McpRequestError =
  ## As above for the version of `ctx`'s request; raises McpCapabilityError
  ## when its client did not declare the url mode, because the error asks the
  ## client for something it cannot do.
  ctx.server.requireElicitation(ctx.session, emUrl)
  urlElicitationRequired(ctx.version, elicitations, message)
