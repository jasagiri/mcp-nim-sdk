## The severity levels of `logging/setLevel` and `notifications/message`:
## the syslog levels of RFC 5424, as every version of the specification
## lists them.

import std/options

type
  McpLogLevel* = enum
    ## In ascending order of severity, so that `level >= threshold` is "at
    ## least as severe as".
    mllDebug = "debug"
    mllInfo = "info"
    mllNotice = "notice"
    mllWarning = "warning"
    mllError = "error"
    mllCritical = "critical"
    mllAlert = "alert"
    mllEmergency = "emergency"

func parseLogLevel*(s: string): Option[McpLogLevel] {.raises: [].} =
  for level in McpLogLevel:
    if $level == s:
      return some(level)
  none(McpLogLevel)
