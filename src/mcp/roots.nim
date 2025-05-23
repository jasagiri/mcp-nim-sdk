# Model Context Protocol (MCP) Server SDK for Nim
#
# This module implements the roots API for MCP,
# providing functionality for root resource discovery and navigation.

import json, tables, asyncdispatch, options, strformat, sequtils, strutils, uri
import types, logger, protocol, resources

proc debug(message: string, args: varargs[string, `$`]) =
  # Placeholder for actual debug logging
  echo message

type
  Root* = object
    uri*: string             # URI identifying the root
    name*: string            # Human-readable name
    description*: Option[string] # Optional description
    
  RootManager* = ref object
    roots*: Table[string, Root]  # Mapping of URIs to roots
    eventHandlers*: Table[string, proc(uri: string, action: RootChangeAction) {.async.}]
    
  RootChangeAction* = enum
    RootAdded, RootRemoved, RootModified
    
  RootNotFoundError* = object of CatchableError

# Root manager implementation
proc newRootManager*(): RootManager =
  ## Creates a new root manager for tracking available roots
  result = RootManager(
    roots: initTable[string, Root](),
    eventHandlers: initTable[string, proc(uri: string, action: RootChangeAction) {.async.}]()
  )

proc addRoot*(manager: RootManager, uri: string, name: string, description: string = ""): bool =
  ## Adds a root to the manager
  ## Returns true if the root was added, false if it already existed
  if manager.roots.hasKey(uri):
    return false
    
  var root = Root(
    uri: uri,
    name: name
  )
  
  if description.len > 0:
    root.description = some(description)
  else:
    root.description = none(string)
  
  manager.roots[uri] = root
  
  # Notify event handlers
  for id, handler in manager.eventHandlers:
    asyncCheck handler(uri, RootAdded)
    
  return true

proc removeRoot*(manager: RootManager, uri: string): bool =
  ## Removes a root from the manager
  ## Returns true if the root was removed, false if it didn't exist
  if not manager.roots.hasKey(uri):
    return false
    
  manager.roots.del(uri)
  
  # Notify event handlers
  for id, handler in manager.eventHandlers:
    asyncCheck handler(uri, RootRemoved)
    
  return true

proc updateRoot*(manager: RootManager, uri: string, name: Option[string] = none(string),
                description: Option[string] = none(string)): bool =
  ## Updates a root's metadata
  ## Returns true if the root was updated, false if it didn't exist
  if not manager.roots.hasKey(uri):
    return false
    
  var root = manager.roots[uri]
  var modified = false
  
  if name.isSome:
    root.name = name.get
    modified = true
    
  if description.isSome:
    root.description = description
    modified = true
    
  if modified:
    manager.roots[uri] = root
    
    # Notify event handlers
    for id, handler in manager.eventHandlers:
      asyncCheck handler(uri, RootModified)
      
  return modified

proc getRootByUri*(manager: RootManager, uri: string): Option[Root] =
  ## Gets a root by its URI
  ## Returns none if the root doesn't exist
  if manager.roots.hasKey(uri):
    return some(manager.roots[uri])
  else:
    return none(Root)
    
proc getAllRoots*(manager: RootManager): seq[Root] =
  ## Gets all roots in the manager
  result = newSeq[Root]()
  for uri, root in manager.roots:
    result.add(root)

proc onRootChange*(manager: RootManager, id: string, 
                  handler: proc(uri: string, action: RootChangeAction) {.async.}): void =
  ## Registers a handler for root change events
  manager.eventHandlers[id] = handler
  
proc removeRootChangeHandler*(manager: RootManager, id: string): bool =
  ## Removes a root change handler
  ## Returns true if the handler was removed, false if it didn't exist
  if not manager.eventHandlers.hasKey(id):
    return false
    
  manager.eventHandlers.del(id)
  return true

proc clearRootChangeHandlers*(manager: RootManager): void =
  ## Removes all root change handlers
  manager.eventHandlers.clear()

# Extension methods for Protocol
proc setupRootsHandlers*(protocol: Protocol, rootManager: RootManager): void =
  ## Sets up request handlers for roots-related methods

  # Handler for roots/list
  let listHandler = proc(request: RequestMessage): ResponseMessage =
    let roots = rootManager.getAllRoots()
    var rootsArray = newJArray()

    for root in roots:
      var rootObj = %* {
        "uri": root.uri,
        "name": root.name
      }

      if isSome(root.description):
        rootObj["description"] = %get(root.description)

      rootsArray.add(rootObj)

    let result = %* {
      "roots": rootsArray
    }

    return ResponseMessage(
      id: request.id,
      result: some(result),
      error: none(ErrorInfo)
    )

  protocol.setRequestHandler("roots/list", listHandler)
  
  # Root notifications
  let rootAddedHandler = proc(uri: string, action: RootChangeAction) {.async.} =
    if action != RootAdded:
      return
      
    let rootOpt = rootManager.getRootByUri(uri)
    if rootOpt.isNone:
      return
      
    let root = rootOpt.get()
    var rootObj = %* {
      "uri": root.uri,
      "name": root.name
    }
    
    if root.description.isSome:
      rootObj["description"] = %root.description.get()
      
    let params = %* {
      "root": rootObj
    }
    
    # This notification would be sent by the server implementation
    debug("Root added: {0}", uri)
    
  let rootRemovedHandler = proc(uri: string, action: RootChangeAction) {.async.} =
    if action != RootRemoved:
      return
      
    let params = %* {
      "uri": uri
    }
    
    # This notification would be sent by the server implementation
    debug("Root removed: {0}", uri)
    
  let rootModifiedHandler = proc(uri: string, action: RootChangeAction) {.async.} =
    if action != RootModified:
      return
      
    let rootOpt = rootManager.getRootByUri(uri)
    if rootOpt.isNone:
      return
      
    let root = rootOpt.get()
    var rootObj = %* {
      "uri": root.uri,
      "name": root.name
    }
    
    if root.description.isSome:
      rootObj["description"] = %root.description.get()
      
    let params = %* {
      "root": rootObj
    }
    
    # This notification would be sent by the server implementation
    debug("Root modified: {0}", uri)
    
  # Register the root change handlers
  rootManager.onRootChange("protocol-roots-added", rootAddedHandler)
  rootManager.onRootChange("protocol-roots-removed", rootRemovedHandler)
  rootManager.onRootChange("protocol-roots-modified", rootModifiedHandler)

# Root URI resolution and manipulation

proc isValidRootUri*(uri: string): bool =
  ## Checks if a URI is a valid root URI
  ## A valid root URI must have a scheme and no spaces
  if uri.len == 0:
    return false

  # Simple validation for the test
  let parsedUri = parseUri(uri)
  if parsedUri.scheme.len == 0:
    return false

  # Check for spaces
  if uri.contains(" "):
    return false

  return true

proc normalizeRootUri*(uri: string): string =
  ## Normalizes a root URI by removing trailing slashes
  result = uri.strip(trailing = true, chars = {'/'})
  if result.len == 0:
    result = "/"

proc combineUri*(base: string, path: string): string =
  ## Combines a base URI with a path
  ## Example: combineUri("file:///foo", "bar") => "file:///foo/bar"
  let baseUri = parseUri(base)
  if path.len == 0:
    return $baseUri
    
  if path[0] == '/':
    var uri = baseUri
    uri.path = path
    return $uri
  else:
    var uri = baseUri
    if uri.path.len == 0:
      uri.path = "/"
    elif uri.path[^1] != '/':
      uri.path &= "/"
    uri.path &= path
    return $uri

proc getParentUri*(uri: string): string =
  ## Gets the parent URI of a URI
  ## Example: getParentUri("file:///foo/bar") => "file:///foo"
  let parsedUri = parseUri(uri)
  if parsedUri.path.len == 0 or parsedUri.path == "/":
    return uri  # No parent
    
  var path = parsedUri.path
  if path[^1] == '/':
    path = path[0..^2]  # Remove trailing slash
    
  let lastSlash = path.rfind('/')
  if lastSlash < 0:
    path = "/"  # Root path
  else:
    path = path[0..lastSlash]
    
  var parentUri = parsedUri
  parentUri.path = path
  return $parentUri

proc resolveUri*(rootManager: RootManager, uri: string): Option[tuple[root: Root, subPath: string]] =
  ## Resolves a URI to a root and a sub-path within that root
  ## Returns none if the URI doesn't match any root
  let parsedUri = parseUri(uri)
  
  # Try exact match first
  if rootManager.roots.hasKey(uri):
    return some((rootManager.roots[uri], ""))
    
  # Find the longest matching root prefix
  var matchedRoot: Option[Root] = none(Root)
  var matchedPrefix = ""
  
  for rootUri, root in rootManager.roots:
    let rootParsedUri = parseUri(rootUri)
    
    # Check if schemes match
    if rootParsedUri.scheme != parsedUri.scheme:
      continue
      
    # Check if the root is a prefix of the URI
    if parsedUri.hostname == rootParsedUri.hostname and
       parsedUri.path.startsWith(rootParsedUri.path):
       
      # Found a match, check if it's longer than the current match
      if rootParsedUri.path.len > matchedPrefix.len:
        matchedRoot = some(root)
        matchedPrefix = rootParsedUri.path
  
  if matchedRoot.isNone:
    return none(tuple[root: Root, subPath: string])
    
  # Calculate the sub-path
  var subPath = parsedUri.path[matchedPrefix.len..^1]
  if subPath.len > 0 and subPath[0] == '/':
    subPath = subPath[1..^1]  # Remove leading slash
    
  return some((matchedRoot.get(), subPath))

# Root-based resource management

proc getRootResources*(rootManager: RootManager, rootUri: string): Future[seq[types.Resource]] {.async.} =
  ## Gets all resources in a root
  ## Raises RootNotFoundError if the root doesn't exist
  if not rootManager.roots.hasKey(rootUri):
    var ex = newException(RootNotFoundError, fmt"Root not found: {rootUri}")
    raise ex

  # This would typically involve fetching resources from a provider
  # For now, return an empty list
  return @[]

proc getResourceAtPath*(rootManager: RootManager, rootUri: string, path: string): Future[Option[types.Resource]] {.async.} =
  ## Gets a resource at a specific path in a root
  ## Returns none if the resource doesn't exist
  if not rootManager.roots.hasKey(rootUri):
    return none(types.Resource)

  # This would typically involve fetching the resource from a provider
  # For now, return none
  return none(types.Resource)

# Root change notifications
proc notifyRootAdded*(protocol: Protocol, root: Root): void =
  ## Sends a notification that a root has been added
  var rootObj = %* {
    "uri": root.uri,
    "name": root.name
  }

  if isSome(root.description):
    rootObj["description"] = %get(root.description)

  let params = %* {
    "root": rootObj
  }

  # This notification would be sent by the server implementation
  debug("Root added notification: {0}", root.uri)

proc notifyRootRemoved*(protocol: Protocol, uri: string): void =
  ## Sends a notification that a root has been removed
  let params = %* {
    "uri": uri
  }

  # This notification would be sent by the server implementation
  debug("Root removed notification: {0}", uri)

proc notifyRootModified*(protocol: Protocol, root: Root): void =
  ## Sends a notification that a root has been modified
  var rootObj = %* {
    "uri": root.uri,
    "name": root.name
  }

  if isSome(root.description):
    rootObj["description"] = %get(root.description)

  let params = %* {
    "root": rootObj
  }

  # This notification would be sent by the server implementation
  debug("Root modified notification: {0}", root.uri)

# Root schema validation

let RootSchema* = %* {
  "type": "object",
  "properties": {
    "uri": {
      "type": "string",
      "description": "URI identifying the root"
    },
    "name": {
      "type": "string",
      "description": "Human-readable name for the root"
    },
    "description": {
      "type": "string",
      "description": "Optional description of the root"
    }
  },
  "required": ["uri", "name"],
  "additionalProperties": false
}

let ListRootsRequestSchema* = %* {
  "type": "object",
  "properties": {
    "cursor": {
      "type": "string",
      "description": "Optional cursor for pagination"
    }
  },
  "additionalProperties": false
}

# Root registry for compatibility with tests
type
  RootRegistry* = ref object
    ## Registry for root URIs with client subscriptions
    roots*: Table[string, struct]
    subscribers*: Table[string, seq[string]]

  struct = object
    uri*: string
    name*: Option[string]

proc newRootRegistry*(): RootRegistry =
  ## Creates a new root registry
  result = RootRegistry(
    roots: initTable[string, struct](),
    subscribers: initTable[string, seq[string]]()
  )

proc addRoot*(registry: RootRegistry, uri: string, name: Option[string] = none(string)) =
  ## Adds a root to the registry
  registry.roots[uri] = struct(uri: uri, name: name)

proc removeRoot*(registry: RootRegistry, uri: string) =
  ## Removes a root from the registry
  if registry.roots.hasKey(uri):
    registry.roots.del(uri)

    # Remove subscribers for this root too
    if registry.subscribers.hasKey(uri):
      registry.subscribers.del(uri)

proc getRoots*(registry: RootRegistry): seq[struct] =
  ## Gets all roots in the registry
  result = newSeq[struct]()
  for uri, root in registry.roots:
    result.add(root)

proc getRootDefinitions*(registry: RootRegistry): JsonNode =
  ## Gets all root definitions in JSON format
  var rootDefs = newJArray()

  for uri, root in registry.roots:
    var rootObj = %* {
      "uri": uri
    }

    if isSome(root.name):
      rootObj["name"] = %get(root.name)

    rootDefs.add(rootObj)

  return rootDefs

proc subscribeRoot*(registry: RootRegistry, uri: string, clientId: string) =
  ## Subscribes a client to a root
  if not registry.roots.hasKey(uri):
    return

  if not registry.subscribers.hasKey(uri):
    registry.subscribers[uri] = @[]

  if clientId notin registry.subscribers[uri]:
    registry.subscribers[uri].add(clientId)

proc unsubscribeRoot*(registry: RootRegistry, uri: string, clientId: string) =
  ## Unsubscribes a client from a root
  if not registry.subscribers.hasKey(uri):
    return

  let idx = registry.subscribers[uri].find(clientId)
  if idx >= 0:
    registry.subscribers[uri].delete(idx)

    # Remove the empty list if no subscribers remain
    if registry.subscribers[uri].len == 0:
      registry.subscribers.del(uri)

proc getSubscribers*(registry: RootRegistry, uri: string): seq[string] =
  ## Gets all subscribers to a root
  if registry.subscribers.hasKey(uri):
    return registry.subscribers[uri]
  else:
    return @[]

proc clearAllSubscriptions*(registry: RootRegistry, clientId: string) =
  ## Removes all subscriptions for a client
  var urisToRemove: seq[string] = @[]

  for uri, subscribers in registry.subscribers:
    let idx = subscribers.find(clientId)
    if idx >= 0:
      registry.subscribers[uri].delete(idx)

      # Mark for removal if no subscribers remain
      if registry.subscribers[uri].len == 0:
        urisToRemove.add(uri)

  # Remove empty subscriber lists
  for uri in urisToRemove:
    registry.subscribers.del(uri)

proc hasRootAccess*(registry: RootRegistry, uri: string, clientId: string): bool =
  ## Checks if a client has access to a root
  ## Basic implementation: client has access if the root exists
  return registry.roots.hasKey(uri)

# Root registration with Server/Client
