## MCP client utilities: ping, logging level, argument completion.

import asyncdispatch, json, options
import ./client
import ./content
import ../protocol/types
import ../protocol/features

type
  McpLogLevel* = enum
    mllDebug = "debug"
    mllInfo = "info"
    mllNotice = "notice"
    mllWarning = "warning"
    mllError = "error"
    mllCritical = "critical"
    mllAlert = "alert"
    mllEmergency = "emergency"

  McpCompletionRefKind* = enum
    mcrPrompt = "ref/prompt"
    mcrResourceTemplate = "ref/resource"

  McpCompletionRef* = object
    ## What is being completed: a prompt's argument or a resource
    ## template's variable.
    case kind*: McpCompletionRefKind
    of mcrPrompt:
      promptName*: string
    of mcrResourceTemplate:
      uriTemplate*: string

  McpCompletion* = object
    values*: seq[string]
    total*: Option[int]
    hasMore*: bool

proc promptRef*(name: string): McpCompletionRef =
  McpCompletionRef(kind: mcrPrompt, promptName: name)

proc resourceTemplateRef*(uriTemplate: string): McpCompletionRef =
  McpCompletionRef(kind: mcrResourceTemplate, uriTemplate: uriTemplate)

proc ping*(client: McpClient,
           options: McpRequestOptions = McpRequestOptions()) {.async.} =
  ## Succeeds when the server answers. Before 2026-07-28 only.
  client.requireFeature(ftPing, "ping")
  discard await client.callMethod("ping", newJObject(), options)

proc setLoggingLevel*(client: McpClient, level: McpLogLevel,
                      options: McpRequestOptions = McpRequestOptions()) {.async.} =
  ## Ask the server to send notifications/message at `level` and above
  ## (see `client.onLogMessage`). Before 2026-07-28 only.
  client.requireFeature(ftLoggingSetLevel, "logging/setLevel")
  client.requireServerCapability(
    client.serverCapabilities.isSome and client.serverCapabilities.get.logging.isSome,
    "logging/setLevel", "logging")
  discard await client.callMethod("logging/setLevel", %*{"level": $level}, options)

proc requestCompletion(client: McpClient, params: JsonNode,
                       options: McpRequestOptions): Future[McpCompletion] {.async.} =
  let reply = await client.callMethod("completion/complete", params, options)
  let completion = reply{"completion"}
  if completion.isNil or completion.kind != JObject:
    raise newException(McpProtocolError, "completion/complete: missing 'completion'")
  for value in requiredArray(completion, "values", "completion/complete"):
    result.values.add value.getStr()
  if completion.hasKey("total"):
    result.total = some(completion["total"].getInt())
  result.hasMore = completion{"hasMore"}.getBool(false)

proc complete*(client: McpClient, reference: McpCompletionRef,
               argumentName, argumentValue: string,
               context: openArray[(string, string)] = [],
               options: McpRequestOptions = McpRequestOptions()): Future[McpCompletion] =
  ## Suggestions for the value of one argument. `context` carries the
  ## arguments already resolved (2025-06-18 and later).
  if client.negotiatedVersion.isNone:
    raise newException(McpConnectionClosedError, "completion/complete: the client is not connected")
  # 2024-11-05 servers complete without declaring the capability.
  if client.negotiatedVersion.get.has(ftCompletionsCapability):
    client.requireServerCapability(
      client.serverCapabilities.isSome and client.serverCapabilities.get.completions.isSome,
      "completion/complete", "completions")
  let refJson =
    case reference.kind
    of mcrPrompt: %*{"type": $reference.kind, "name": reference.promptName}
    of mcrResourceTemplate: %*{"type": $reference.kind, "uri": reference.uriTemplate}
  var params = %*{"ref": refJson,
                  "argument": {"name": argumentName, "value": argumentValue}}
  if context.len > 0:
    client.requireFeature(ftCompletionContext, "completion/complete (context)")
    let resolved = newJObject()
    for (key, value) in context:
      resolved[key] = %value
    params["context"] = %*{"arguments": resolved}
  client.requestCompletion(params, options)
