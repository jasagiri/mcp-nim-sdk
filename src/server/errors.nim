## What a server handler raises to say which JSON-RPC error, or which tool
## result, the peer gets. Any other exception a handler raises is a defect of
## the server: the peer is told "Internal error" and the cause goes to stderr.

import std/[json, options]
import ../protocol/modern
import ../protocol/diagnostic

export diagnostic.plainMessage

const
  ErrInvalidRequest* = -32600
  ErrResourceNotFoundLegacy* = -32002
  ErrRateLimited* = 429
    ## The specification names no code for a request refused because its
    ## sender is too fast. Of the JSON-RPC range (-32768 to -32000), 2026-07-28
    ## basic/index reserves -32020 and below to MCP ("Implementations MUST NOT
    ## emit any code from this sub-range that is not defined by this
    ## specification") and asks that "New error codes for purposes not defined
    ## by this specification SHOULD be allocated outside the JSON-RPC reserved
    ## range". 429 is outside it, and is the HTTP status that says the same.
    ## The code for an unknown resource before 2026-07-28.

type
  McpRequestError* = object of CatchableError
    ## Answer the request with a JSON-RPC error.
    code*: int
    data*: JsonNode

  McpInputRequired* = object of CatchableError
    ## 2026-07-28 multi round-trip requests: answer with `input_required`
    ## instead of a result; see `server/mrtr`.
    inputRequests*: JsonNode
      ## Key -> request object; nil when the answer carries only state.
    requestState*: Option[string]

  McpResourceNotFound* = object of CatchableError
    ## The resource does not exist. Its code depends on the protocol version
    ## of the request, so the server chooses it.
    uri*: string

  McpToolFailure* = object of CatchableError
    ## The tool ran and failed: the peer gets a result with `isError: true`
    ## and this message as its text, which a model can read and act on.

  McpCancelled* = object of CatchableError
    ## Raised by `checkCancelled` once the client has cancelled the request.

  McpCapabilityError* = object of CatchableError
    ## The operation needs something the server did not declare, or the peer
    ## did not offer, or the protocol version of the peer does not have.

  McpRemoteError* = object of CatchableError
    ## The peer answered a request of this server with a JSON-RPC error.
    code*: int
    data*: JsonNode

  McpRequestTimeout* = object of CatchableError
    ## The peer did not answer a request of this server in time.

func newRequestError*(code: int, message: string,
                      data: JsonNode = nil): ref McpRequestError =
  (ref McpRequestError)(code: code, msg: message, data: data)

func newInvalidParams*(message: string): ref McpRequestError =
  newRequestError(ErrInvalidParams, message)

func newInvalidCursor*(): ref McpRequestError =
  newRequestError(ErrInvalidParams, "Invalid cursor")

func newUnknownTool*(name: string): ref McpRequestError =
  newRequestError(ErrInvalidParams, "Unknown tool: " & name)

func newResourceNotFound*(uri: string): ref McpResourceNotFound =
  (ref McpResourceNotFound)(msg: "Resource not found", uri: uri)

func newToolFailure*(message: string): ref McpToolFailure =
  (ref McpToolFailure)(msg: message)
