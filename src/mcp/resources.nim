## Resource handling implementation for the Model Context Protocol (MCP).
##
## This module provides utilities for working with MCP resources.

import json
import options
import base64
import os
import strutils
import tables
import asyncdispatch
import strformat

type
  ResourceType* = enum
    ## Types of resources
    TextResource,  ## Text-based resource
    BinaryResource ## Binary resource

  ResourceUri* = object
    ## Parsed resource URI
    protocol*: string
    path*: string

  Resource* = object
    ## Base resource object
    uri*: string
    name*: string
    description*: string
    mimeType*: Option[string]
    
    case resourceType*: ResourceType
    of TextResource:
      text*: string
    of BinaryResource:
      binaryData*: string  # Base64-encoded data

  ResourceTemplate* = object
    ## Resource template for dynamic resources
    uriTemplate*: string
    name*: string
    description*: string
    mimeType*: Option[string]

  ResourceContentHandler* = proc(): JsonNode

  ResourceRegistry* = ref object
    ## Registry for resources
    resources*: Table[string, JsonNode]
    resourceHandlers*: Table[string, ResourceContentHandler]
    resourceTemplates*: Table[string, JsonNode]

proc newTextResource*(uri, name, text: string, description = "", mimeType = ""): Resource =
  ## Create a new text resource
  var mime = if mimeType.len > 0: some(mimeType) else: none(string)
  
  result = Resource(
    uri: uri,
    name: name,
    description: description,
    mimeType: mime,
    resourceType: TextResource,
    text: text
  )

proc newBinaryResource*(uri, name, filePath: string, description = "", mimeType = ""): Resource =
  ## Create a new binary resource from a file
  let fileData = readFile(filePath)
  let encodedData = encode(fileData)
  
  var mime = if mimeType.len > 0: some(mimeType) else: none(string)
  
  result = Resource(
    uri: uri,
    name: name,
    description: description,
    mimeType: mime,
    resourceType: BinaryResource,
    binaryData: encodedData
  )

proc newBinaryResourceFromData*(uri, name: string, data: string, description = "", mimeType = ""): Resource =
  ## Create a new binary resource from raw data
  let encodedData = encode(data)
  
  var mime = if mimeType.len > 0: some(mimeType) else: none(string)
  
  result = Resource(
    uri: uri,
    name: name,
    description: description,
    mimeType: mime,
    resourceType: BinaryResource,
    binaryData: encodedData
  )

proc newResourceTemplate*(uriTemplate, name: string, description = "", mimeType = ""): ResourceTemplate =
  ## Create a new resource template
  var mime = if mimeType.len > 0: some(mimeType) else: none(string)
  
  result = ResourceTemplate(
    uriTemplate: uriTemplate,
    name: name,
    description: description,
    mimeType: mime
  )

proc toContentJson*(res: Resource): JsonNode =
  ## Convert a resource to its content JSON representation
  result = %{
    "uri": %res.uri
  }
  
  if res.mimeType.isSome:
    result["mimeType"] = %res.mimeType.get()
  
  case res.resourceType
  of TextResource:
    result["text"] = %res.text
  of BinaryResource:
    result["blob"] = %res.binaryData

proc toInfoJson*(res: Resource): JsonNode =
  ## Convert a resource to its info JSON representation
  result = %{
    "uri": %res.uri,
    "name": %res.name
  }
  
  if res.description.len > 0:
    result["description"] = %res.description
    
  if res.mimeType.isSome:
    result["mimeType"] = %res.mimeType.get()

proc toInfoJson*(templ: ResourceTemplate): JsonNode =
  ## Convert a resource template to its info JSON representation
  result = %{
    "uriTemplate": %templ.uriTemplate,
    "name": %templ.name
  }
  
  if templ.description.len > 0:
    result["description"] = %templ.description
    
  if templ.mimeType.isSome:
    result["mimeType"] = %templ.mimeType.get()

proc guessMimeType*(filePath: string): string =
  ## Guess the MIME type of a file based on its extension
  let ext = toLowerAscii(splitFile(filePath).ext)
  
  case ext
  of ".txt":
    return "text/plain"
  of ".html", ".htm":
    return "text/html"
  of ".css":
    return "text/css"
  of ".js":
    return "application/javascript"
  of ".json":
    return "application/json"
  of ".xml":
    return "application/xml"
  of ".png":
    return "image/png"
  of ".jpg", ".jpeg":
    return "image/jpeg"
  of ".gif":
    return "image/gif"
  of ".svg":
    return "image/svg+xml"
  of ".pdf":
    return "application/pdf"
  of ".zip":
    return "application/zip"
  of ".md":
    return "text/markdown"
  of ".csv":
    return "text/csv"
  else:
    return "application/octet-stream"

proc validateResourceUri*(uri: string): bool =
  ## Validate a resource URI
  ##
  ## Valid URIs must:
  ## - Have a scheme (protocol) part
  ## - Have a path part
  ## - Not be empty

  if uri.len == 0:
    return false

  # Handle special case for data URIs which use single colon
  if uri.startsWith("data:"):
    return uri.len > 5  # Must have something after "data:"

  # Standard URI format with "://"
  let schemeSep = uri.find("://")
  if schemeSep <= 0:
    return false

  let pathStart = schemeSep + 3
  if pathStart >= uri.len:
    return false

  true

proc parseResourceUri*(uri: string): ResourceUri =
  ## Parse a resource URI into its protocol and path components
  ## Assumes the URI has already been validated with validateResourceUri

  # Handle data URIs
  if uri.startsWith("data:"):
    let colonPos = uri.find(":")
    let protocol = uri[0..<colonPos]
    let path = uri[(colonPos + 1)..^1]
    return ResourceUri(protocol: protocol, path: path)

  # Handle standard URIs
  let schemeSep = uri.find("://")
  if schemeSep <= 0:
    # Default to empty values if invalid URI
    return ResourceUri(protocol: "", path: "")

  let protocol = uri[0..<schemeSep]
  let path = uri[(schemeSep + 3)..^1]

  result = ResourceUri(
    protocol: protocol,
    path: path
  )

proc newResource*(uri, name: string, description: Option[string] = none(string),
                 mimeType: Option[string] = none(string)): JsonNode =
  ## Create a new resource JSON representation
  result = %*{
    "uri": uri,
    "name": name
  }

  if description.isSome:
    result["description"] = %description.get()

  if mimeType.isSome:
    result["mimeType"] = %mimeType.get()

proc newResourceRegistry*(): ResourceRegistry =
  ## Create a new resource registry
  result = ResourceRegistry(
    resources: initTable[string, JsonNode](),
    resourceHandlers: initTable[string, ResourceContentHandler](),
    resourceTemplates: initTable[string, JsonNode]()
  )

proc registerResource*(registry: ResourceRegistry, uri, name: string,
                      description: Option[string] = none(string),
                      mimeType: Option[string] = none(string),
                      handler: ResourceContentHandler = nil): void =
  ## Register a resource with the registry
  var resourceInfo = newResource(uri, name, description, mimeType)
  registry.resources[uri] = resourceInfo

  if handler != nil:
    registry.resourceHandlers[uri] = handler

proc getResources*(registry: ResourceRegistry): seq[JsonNode] =
  ## Get all registered resources
  result = @[]
  for uri, info in registry.resources:
    result.add(info)

proc getResource*(registry: ResourceRegistry, uri: string): Option[JsonNode] =
  ## Get the content of a specific resource
  if uri notin registry.resourceHandlers:
    return none(JsonNode)

  try:
    let content = registry.resourceHandlers[uri]()
    return some(content)
  except:
    return none(JsonNode)

proc registerResourceTemplate*(registry: ResourceRegistry, uriTemplate, name: string,
                             description: Option[string] = none(string),
                             mimeType: Option[string] = none(string)): void =
  ## Register a resource template with the registry
  var templateInfo = %*{
    "uriTemplate": uriTemplate,
    "name": name
  }

  if description.isSome:
    templateInfo["description"] = %description.get()

  if mimeType.isSome:
    templateInfo["mimeType"] = %mimeType.get()

  registry.resourceTemplates[uriTemplate] = templateInfo

proc getResourceTemplates*(registry: ResourceRegistry): seq[JsonNode] =
  ## Get all registered resource templates
  result = @[]
  for uriTemplate, info in registry.resourceTemplates:
    result.add(info)
