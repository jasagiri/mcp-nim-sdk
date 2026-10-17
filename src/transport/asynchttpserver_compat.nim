## The HTTP server the transports run on: `std/asynchttpserver` as of Nim
## 2.3.1, which bounds how long a request may take to arrive (`readTimeout`).
## A compiler older than that gets the same module, copied into vendor/.

when (NimMajor, NimMinor, NimPatch) >= (2, 3, 1):
  import std/asynchttpserver
  export asynchttpserver
else:
  import ./vendor/asynchttpserver
  export asynchttpserver
