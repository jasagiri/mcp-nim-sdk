## What the HTTP transports need from an authorization implementation, and
## nothing more. `auth/client` and `auth/resource_server` build these; the
## transports do not import them.

import std/[asyncdispatch, options]

type
  HttpClientAuth* = ref object
    ## Client side, held by `StreamableHttpTransport.auth`.
    authorization*: proc(): Future[Option[string]] {.closure, gcsafe.}
      ## The Authorization header value for the next request, if there is
      ## one. Asked before every request.
    onChallenge*: proc(status: int, wwwAuthenticate: seq[string]): Future[bool]
                      {.closure, gcsafe.}
      ## A request was answered 401 or 403 with these WWW-Authenticate values.
      ## True: the situation was improved (new token), send the request again.
      ## False: nothing to be done; the answer is reported as an error. May
      ## raise when authorization failed in a way worth reporting.

  HttpServerAuthResponse* = object
    code*: int
    headers*: seq[(string, string)]
    body*: string

  HttpServerAuthOutcome* = object
    ## What the hook decided about one HTTP request.
    answer*: Option[HttpServerAuthResponse]
      ## Some: the request is answered here (metadata document, 401, 403).
    principal*: Option[string]
      ## When the request goes on: who sent it (the subject of the verified
      ## token), as the MCP server and its handlers will see it
      ## (`ctx.principal`); none when the hook cannot say.

  HttpServerAuth* = ref object
    ## Server side, held by `HttpServerTransport.auth`. A hook sets `check`,
    ## which also names the principal; `intercept` alone is enough where no
    ## handler needs to know who is asking.
    check*: proc(httpMethod, path: string, authorization: Option[string]):
                Future[HttpServerAuthOutcome] {.closure, gcsafe.}
      ## Used instead of `intercept` when set.
    intercept*: proc(httpMethod, path: string, authorization: Option[string]):
                    Future[Option[HttpServerAuthResponse]] {.closure, gcsafe.}
      ## Asked first for every HTTP request. A response answers the request
      ## itself (metadata document, 401, 403); none lets it proceed.
