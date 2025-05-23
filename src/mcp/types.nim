## Core types for the Model Context Protocol (MCP).
## 
## This module defines the fundamental data structures used throughout the MCP implementation,
## including protocol messages, capabilities, resources, tools, and more.

import std/options
import std/json

type
  # Protocol version information
  ProtocolVersion* = object
    major*: int
    minor*: int
    patch*: int

  # Implementation information
  Implementation* = object
    name*: string
    version*: string

  # Role in message exchanges
  Role* = enum
    User = "user"
    Assistant = "assistant"

  # Server capability types
  ResourcesCapability* = object
    listChanged*: Option[bool]
  
  ToolsCapability* = object
    listChanged*: Option[bool]

  PromptsCapability* = object
    listChanged*: Option[bool]

  RootsCapability* = object
    listChanged*: Option[bool]

  SamplingCapability* = object
    discard

  # Server capabilities
  ServerCapabilities* = object
    resources*: Option[ResourcesCapability]
    tools*: Option[ToolsCapability]
    prompts*: Option[PromptsCapability]
    roots*: Option[RootsCapability]
    sampling*: Option[SamplingCapability]

# JSON conversion for capability types
proc `%`*(x: ResourcesCapability): JsonNode =
  result = newJObject()
  if x.listChanged.isSome:
    result["listChanged"] = %x.listChanged.get()

proc `%`*(x: ToolsCapability): JsonNode =
  result = newJObject()
  if x.listChanged.isSome:
    result["listChanged"] = %x.listChanged.get()

proc `%`*(x: PromptsCapability): JsonNode =
  result = newJObject()
  if x.listChanged.isSome:
    result["listChanged"] = %x.listChanged.get()

proc `%`*(x: RootsCapability): JsonNode =
  result = newJObject()
  if x.listChanged.isSome:
    result["listChanged"] = %x.listChanged.get()

proc `%`*(x: SamplingCapability): JsonNode =
  newJObject()

proc `%`*(x: ServerCapabilities): JsonNode =
  result = newJObject()
  if x.resources.isSome:
    result["resources"] = %x.resources.get()
  if x.tools.isSome:
    result["tools"] = %x.tools.get()
  if x.prompts.isSome:
    result["prompts"] = %x.prompts.get()
  if x.roots.isSome:
    result["roots"] = %x.roots.get()
  if x.sampling.isSome:
    result["sampling"] = %x.sampling.get()

type
  # Client capabilities
  ClientCapabilities* = object
    sampling*: Option[bool]
    roots*: Option[bool]
    tools*: Option[bool]
    resources*: Option[bool]
    experimental*: Option[JsonNode]

  # Resource types
  Resource* = object
    uri*: string
    name*: string
    description*: Option[string]
    mimeType*: Option[string]

  ResourceTemplate* = object
    uriTemplate*: string
    name*: string
    description*: Option[string]
    mimeType*: Option[string]

  ResourceContentsBase* = object of RootObj
    uri*: string
    mimeType*: Option[string]

  TextResourceContents* = object of ResourceContentsBase
    text*: string

  BlobResourceContents* = object of ResourceContentsBase
    blob*: string  # Base64 encoded

  # Tool types
  Tool* = object
    name*: string
    description*: Option[string]
    inputSchema*: JsonNode

  # Server metadata
  ServerMetadata* = object
    name*: string
    version*: string
    description*: string

  # Content types
  ContentType* = enum
    Text = "text"
    Image = "image"

  Content* = object
    case kind*: ContentType
    of Text:
      text*: string
    of Image:
      data*: string
      mimeType*: string

  # Sampling types
  ModelHint* = object
    name*: Option[string]

  ModelPreferences* = object
    hints*: Option[seq[ModelHint]]
    costPriority*: Option[float]
    speedPriority*: Option[float]
    intelligencePriority*: Option[float]

  ContextInclusion* = enum
    None = "none"
    ThisServer = "thisServer"
    AllServers = "allServers"

  SamplingMessage* = object
    role*: Role
    content*: seq[Content]

  # Error handling
  ErrorCode* = enum
    ParseError = -32700
    InvalidRequest = -32600
    MethodNotFound = -32601
    InvalidParams = -32602
    InternalError = -32603

  ToolResult* = object
    ## Result of a tool invocation
    isError*: bool         ## Whether an error occurred
    content*: seq[JsonNode] ## Content of the result
