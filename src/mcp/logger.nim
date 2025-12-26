# Model Context Protocol (MCP) Server SDK for Nim
#
# Logger implementation for MCP

import std/[options, strutils, times, os, strformat]

type
  LogLevel* = enum
    Debug = "DEBUG"
    Info = "INFO"
    Warning = "WARNING"
    Error = "ERROR"

  Logger* = ref object
    level*: LogLevel
    useColors*: bool
    useTimestamp*: bool
    logFile*: Option[string]

var defaultLogger*: Logger

proc newLogger*(level: LogLevel = Info, useColors: bool = true,
                useTimestamp: bool = true, logFile: Option[string] = none(string)): Logger =
  ## Creates a new logger with the specified settings
  result = Logger(
    level: level,
    useColors: useColors,
    useTimestamp: useTimestamp,
    logFile: logFile
  )

proc setDefaultLogger*(logger: Logger) =
  ## Sets the default logger
  defaultLogger = logger

proc formatMessage(logger: Logger, level: LogLevel, message: string): string =
  ## Formats a log message
  var parts: seq[string] = @[]

  if logger.useTimestamp:
    parts.add(now().format("yyyy-MM-dd HH:mm:ss"))

  parts.add($level)
  parts.add(message)

  result = parts.join(" ")

proc log*(logger: Logger, level: LogLevel, message: string, args: varargs[string, `$`]) =
  ## Logs a message at the specified level
  if level < logger.level:
    return

  var msg = message
  for arg in args:
    let idx = msg.find("{}")
    if idx >= 0:
      msg = msg[0..<idx] & arg & msg[idx+2..^1]

  let formatted = logger.formatMessage(level, msg)

  if logger.logFile.isSome:
    let f = open(logger.logFile.get(), fmAppend)
    f.writeLine(formatted)
    f.close()
  else:
    echo formatted

proc debug*(logger: Logger, message: string, args: varargs[string, `$`]) =
  ## Logs a debug message
  logger.log(Debug, message, args)

proc info*(logger: Logger, message: string, args: varargs[string, `$`]) =
  ## Logs an info message
  logger.log(Info, message, args)

proc warning*(logger: Logger, message: string, args: varargs[string, `$`]) =
  ## Logs a warning message
  logger.log(Warning, message, args)

proc error*(logger: Logger, message: string, args: varargs[string, `$`]) =
  ## Logs an error message
  logger.log(Error, message, args)

proc parseLogLevel(levelStr: string): LogLevel =
  ## Parses a log level from a string
  case levelStr.toLowerAscii():
  of "debug": Debug
  of "info": Info
  of "warning", "warn": Warning
  of "error": Error
  else: Info  # Default to Info

proc initLoggerFromEnv*(): Logger =
  ## Creates a logger from environment variables
  let levelStr = getEnv("MCP_LOG_LEVEL", "info")
  let colors = getEnv("MCP_LOG_COLORS", "true") != "false"
  let timestamp = getEnv("MCP_LOG_TIMESTAMP", "true") != "false"
  let logFileStr = getEnv("MCP_LOG_FILE", "")

  let logFile = if logFileStr.len > 0: some(logFileStr) else: none(string)

  result = newLogger(parseLogLevel(levelStr), colors, timestamp, logFile)

proc initDefaultLoggerFromEnv*() =
  ## Initializes the default logger from environment variables
  defaultLogger = initLoggerFromEnv()

# Convenience methods that use the default logger
proc debug*(message: string, args: varargs[string, `$`]) =
  ## Logs a debug message to the default logger
  if defaultLogger != nil:
    defaultLogger.debug(message, args)

proc info*(message: string, args: varargs[string, `$`]) =
  ## Logs an info message to the default logger
  if defaultLogger != nil:
    defaultLogger.info(message, args)

proc warning*(message: string, args: varargs[string, `$`]) =
  ## Logs a warning message to the default logger
  if defaultLogger != nil:
    defaultLogger.warning(message, args)

proc error*(message: string, args: varargs[string, `$`]) =
  ## Logs an error message to the default logger
  if defaultLogger != nil:
    defaultLogger.error(message, args)

# Initialize default logger
defaultLogger = newLogger()
