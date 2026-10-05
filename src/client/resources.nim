## MCP client resource operations

import asyncdispatch, json, options
import ./client
import ../protocol/types
import ../protocol/features
import ./content
export content

type
  McpResourceContent* = McpEmbeddedResource

  McpResource* = object
    uri*: string
    name*: string
    title*: Option[string]
    description*: Option[string]
    mimeType*: Option[string]
    size*: Option[int]
    icons*: seq[McpIcon]

  McpResourceTemplate* = object
    uriTemplate*: string
    name*: string
    title*: Option[string]
    description*: Option[string]
    mimeType*: Option[string]
    icons*: seq[McpIcon]

func displayName*(resource: McpResource): string =
  ## `title` when the server gave one, else `name`.
  resource.title.get(resource.name)

func displayName*(resourceTemplate: McpResourceTemplate): string =
  resourceTemplate.title.get(resourceTemplate.name)

proc requireResources(client: McpClient, operation: string): McpResourcesCapability =
  if client.serverCapabilities.isNone:
    raise newException(McpConnectionClosedError, operation & ": the client is not connected")
  let resources = client.serverCapabilities.get.resources
  client.requireServerCapability(resources.isSome, operation, "resources")
  resources.get

proc parseResource(item: JsonNode): McpResource =
  McpResource(
    uri: requiredString(item, "uri", "resources/list"),
    name: requiredString(item, "name", "resources/list"),
    title: optionalString(item, "title"),
    description: optionalString(item, "description"),
    mimeType: optionalString(item, "mimeType"),
    size: (if item.hasKey("size"): some(item["size"].getInt()) else: none(int)),
    icons: iconsOf(item, "resources/list"))

proc parseTemplate(item: JsonNode): McpResourceTemplate =
  McpResourceTemplate(
    uriTemplate: requiredString(item, "uriTemplate", "resources/templates/list"),
    name: requiredString(item, "name", "resources/templates/list"),
    title: optionalString(item, "title"),
    description: optionalString(item, "description"),
    mimeType: optionalString(item, "mimeType"),
    icons: iconsOf(item, "resources/templates/list"))

proc listResources*(client: McpClient, cursor: Option[string] = none(string),
                    options: McpRequestOptions = McpRequestOptions()
                   ): Future[tuple[resources: seq[McpResource], nextCursor: Option[string]]] {.async.} =
  discard client.requireResources("resources/list")
  let reply = await client.callMethod("resources/list", pageParams(cursor), options)
  var resources: seq[McpResource]
  for item in requiredArray(reply, "resources", "resources/list"):
    resources.add parseResource(item)
  return (resources: resources, nextCursor: parseNextCursor(reply))

proc listAllResources*(client: McpClient,
                       options: McpRequestOptions = McpRequestOptions()): Future[seq[McpResource]] =
  allPages("resources/list", proc(cursor: Option[string]): Future[tuple[items: seq[McpResource], next: Option[string]]] {.async.} =
    let page = await client.listResources(cursor, options)
    return (items: page.resources, next: page.nextCursor))

proc listResourceTemplates*(client: McpClient, cursor: Option[string] = none(string),
                            options: McpRequestOptions = McpRequestOptions()
                           ): Future[tuple[templates: seq[McpResourceTemplate], nextCursor: Option[string]]] {.async.} =
  discard client.requireResources("resources/templates/list")
  let reply = await client.callMethod("resources/templates/list", pageParams(cursor), options)
  var templates: seq[McpResourceTemplate]
  for item in requiredArray(reply, "resourceTemplates", "resources/templates/list"):
    templates.add parseTemplate(item)
  return (templates: templates, nextCursor: parseNextCursor(reply))

proc listAllResourceTemplates*(client: McpClient,
    options: McpRequestOptions = McpRequestOptions()): Future[seq[McpResourceTemplate]] =
  allPages("resources/templates/list", proc(cursor: Option[string]): Future[tuple[items: seq[McpResourceTemplate], next: Option[string]]] {.async.} =
    let page = await client.listResourceTemplates(cursor, options)
    return (items: page.templates, next: page.nextCursor))

proc readResource*(client: McpClient, uri: string,
                   options: McpRequestOptions = McpRequestOptions()): Future[seq[McpResourceContent]] {.async.} =
  ## The contents of `uri`; a server may answer with several entries.
  discard client.requireResources("resources/read")
  let reply = await client.callMethod("resources/read", %*{"uri": uri}, options)
  for item in requiredArray(reply, "contents", "resources/read"):
    result.add parseEmbeddedResource(item, "resources/read")

proc subscribeResource*(client: McpClient, uri: string,
                        options: McpRequestOptions = McpRequestOptions()) {.async.} =
  ## Ask for notifications/resources/updated on `uri` (see
  ## `client.onResourceUpdated`). Before 2026-07-28 only.
  client.requireFeature(ftResourceSubscribe, "resources/subscribe")
  let caps = client.requireResources("resources/subscribe")
  client.requireServerCapability(caps.subscribe, "resources/subscribe", "resources.subscribe")
  discard await client.callMethod("resources/subscribe", %*{"uri": uri}, options)

proc unsubscribeResource*(client: McpClient, uri: string,
                          options: McpRequestOptions = McpRequestOptions()) {.async.} =
  client.requireFeature(ftResourceSubscribe, "resources/unsubscribe")
  let caps = client.requireResources("resources/unsubscribe")
  client.requireServerCapability(caps.subscribe, "resources/unsubscribe", "resources.subscribe")
  discard await client.callMethod("resources/unsubscribe", %*{"uri": uri}, options)
