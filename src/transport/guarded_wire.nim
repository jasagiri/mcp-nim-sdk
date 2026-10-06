## A request over `http_wire` to a destination that has been judged: the host
## is resolved here, every address is checked against a `DestinationPolicy`
## (`address_policy`), and the connection goes to the address that passed.
## What OAuth metadata and token requests, Server Cards, AI Catalogs and icons
## have in common: the URL came from the network.

import std/[asyncdispatch, httpcore, net, uri]
import ./address_policy
import ./http_wire

export address_policy.AddressNotAllowed

proc guardedRequest*(url: string, httpMethod: HttpMethod, policy: DestinationPolicy,
                     resolver: HostResolver = nil, headers: HttpHeaders = nil,
                     body = "", connected: Connected = nil,
                     followRedirects = false, caFile = "",
                     connectTimeoutMs = DefaultConnectTimeoutMs,
                     headerTimeoutMs = 0): Future[WireResponse] {.async.} =
  ## `http_wire.request` to the address `chooseDestination` picks for the host
  ## of `url`. Raises AddressNotAllowed before anything is connected when the
  ## host is not a destination `policy` allows (see `chooseDestination`), and
  ## for a plain `http` URL unless the host is loopback throughout: only
  ## traffic that does not leave the machine goes unencrypted. Redirects, when
  ## followed, stay on the same origin and so on the same address.
  let target = parseUri(url)
  let destination = chooseDestination(target.hostname, policy, resolver)
  if target.scheme == "http" and not destination.loopbackOnly:
    raise newException(AddressNotAllowed,
      target.hostname & " is not a loopback address: plain http is for loopback only")
  return await request(url, httpMethod, headers, body, connected, followRedirects,
                       connectTo = $destination.address, caFile = caFile,
                       connectTimeoutMs = connectTimeoutMs,
                       headerTimeoutMs = headerTimeoutMs)
