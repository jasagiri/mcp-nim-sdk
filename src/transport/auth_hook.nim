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

  HttpServerAuth* = ref object
    ## Server side, held by `HttpServerTransport.auth`.
    intercept*: proc(httpMethod, path: string, authorization: Option[string]):
                    Future[Option[HttpServerAuthResponse]] {.closure, gcsafe.}
      ## Asked first for every HTTP request. A response answers the request
      ## itself (metadata document, 401, 403); none lets it proceed.
