## `subscriptions/listen` (2026-07-28, basic/patterns/subscriptions): a
## long-lived stream of the change notifications a client opted in to. It
## replaces `resources/subscribe` and the HTTP GET stream.
##
## Pure functions over JSON, shared by the server and the client.

import std/[json, options]
import ./modern

const
  ListenMethod* = "subscriptions/listen"
  AcknowledgedMethod* = "notifications/subscriptions/acknowledged"
  ToolsListChangedMethod* = "notifications/tools/list_changed"
  PromptsListChangedMethod* = "notifications/prompts/list_changed"
  ResourcesListChangedMethod* = "notifications/resources/list_changed"
  ResourceUpdatedMethod* = "notifications/resources/updated"

type
  SubscriptionFilter* = object
    ## The notification types of one subscription; a field left out is a
    ## type not subscribed to.
    toolsListChanged*: bool
    promptsListChanged*: bool
    resourcesListChanged*: bool
    resourceSubscriptions*: seq[string]

func toJson*(filter: SubscriptionFilter): JsonNode {.raises: [].} =
  ## Wire form: only what is subscribed to is present.
  result = newJObject()
  if filter.toolsListChanged: result["toolsListChanged"] = %true
  if filter.promptsListChanged: result["promptsListChanged"] = %true
  if filter.resourcesListChanged: result["resourcesListChanged"] = %true
  if filter.resourceSubscriptions.len > 0:
    result["resourceSubscriptions"] = %filter.resourceSubscriptions

func isEmpty*(filter: SubscriptionFilter): bool {.raises: [].} =
  not filter.toolsListChanged and not filter.promptsListChanged and
    not filter.resourcesListChanged and filter.resourceSubscriptions.len == 0

func parseSubscriptionFilter*(node: JsonNode): tuple[filter: SubscriptionFilter,
                                                      problem: Option[string]] {.raises: [].} =
  ## The filter in `node`, or why it is not one. Keys the specification does
  ## not define are ignored.
  if node.isNil or node.kind != JObject:
    return (SubscriptionFilter(), some("notifications must be an object"))
  for key in ["toolsListChanged", "promptsListChanged", "resourcesListChanged"]:
    let flag = node{key}
    if not flag.isNil and flag.kind != JBool:
      return (SubscriptionFilter(), some(key & " must be a boolean"))
  result.filter.toolsListChanged = node{"toolsListChanged"}.getBool()
  result.filter.promptsListChanged = node{"promptsListChanged"}.getBool()
  result.filter.resourcesListChanged = node{"resourcesListChanged"}.getBool()
  let uris = node{"resourceSubscriptions"}
  if not uris.isNil:
    if uris.kind != JArray:
      return (SubscriptionFilter(), some("resourceSubscriptions must be an array"))
    for uri in uris:
      if uri.kind != JString:
        return (SubscriptionFilter(), some("resourceSubscriptions must hold strings"))
      result.filter.resourceSubscriptions.add uri.getStr()

func subscriptionIdOf*(params: JsonNode): Option[string] {.raises: [].} =
  ## The id of the subscription a notification was delivered on, as text
  ## (the id of the `subscriptions/listen` request is a string or number).
  if params.isNil or params.kind != JObject:
    return none(string)
  let meta = params{"_meta"}
  if meta.isNil or meta.kind != JObject:
    return none(string)
  let id = meta{MetaSubscriptionId}
  if id.isNil: none(string)
  elif id.kind == JString: some(id.getStr())
  elif id.kind == JInt: some($id.getInt())
  else: none(string)

func withSubscriptionId*(params: JsonNode, id: JsonNode): JsonNode {.raises: [].} =
  ## A copy of `params` (an object, or nil) tagged with the subscription id
  ## `id`, exactly as the client's request spelled it.
  result =
    if params.isNil or params.kind != JObject: newJObject()
    else: params.copy()
  var meta = result{"_meta"}
  if meta.isNil or meta.kind != JObject:
    meta = newJObject()
    result["_meta"] = meta
  meta[MetaSubscriptionId] = id

func acknowledgementParams*(id: JsonNode, honored: SubscriptionFilter): JsonNode {.raises: [].} =
  ## The params of `notifications/subscriptions/acknowledged`.
  withSubscriptionId(%*{"notifications": honored.toJson()}, id)

func listenResult*(id: JsonNode): JsonNode {.raises: [].} =
  ## The result with which a server ends a subscription gracefully.
  %*{"resultType": "complete", "_meta": {MetaSubscriptionId: id}}

func wants*(filter: SubscriptionFilter, methodName: string,
            params: JsonNode): bool {.raises: [].} =
  ## Whether a subscription with `filter` receives this notification.
  case methodName
  of ToolsListChangedMethod: filter.toolsListChanged
  of PromptsListChangedMethod: filter.promptsListChanged
  of ResourcesListChangedMethod: filter.resourcesListChanged
  of ResourceUpdatedMethod:
    let uri = if params.isNil or params.kind != JObject: nil else: params{"uri"}
    not uri.isNil and uri.kind == JString and uri.getStr() in filter.resourceSubscriptions
  else: false
