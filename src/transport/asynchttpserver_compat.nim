## The HTTP server the transports run on: `std/asynchttpserver` when it
## keeps each header line whole (`headerFields`, nim-lang/Nim#26460); it
## bounds how long a request may take to arrive (`readTimeout`) since Nim
## 2.3.1, below the oldest Nim this package builds with.
## The standard library's `headers` splits a value at its commas and keeps
## only the last of repeated lines, so a value such as `us-west1,eu-west1`
## cannot be read back as it was sent. A standard library without it gets
## the copy in vendor/, which has both.

import std/asynchttpserver as stdserver

const StdIsEnough = compiles(stdserver.Request().headerFields)

when StdIsEnough:
  export stdserver
else:
  import ./vendor/asynchttpserver
  export asynchttpserver
