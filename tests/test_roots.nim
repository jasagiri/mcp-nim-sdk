# Tests for the MCP Roots functionality
#
# This file contains tests for the Roots capability in the MCP SDK.

import unittest, asyncdispatch, options, json, tables
import ../src/mcp

suite "Roots Management":
  test "Root Registry creation":
    let registry = newRootRegistry()
    check registry != nil
    check registry.roots.len == 0
    check registry.subscribers.len == 0
  
  test "Add and remove roots":
    let registry = newRootRegistry()
    
    # Add a root
    registry.addRoot("file:///home/user", some("User Directory"))
    check registry.roots.len == 1
    check registry.roots.hasKey("file:///home/user")
    check registry.roots["file:///home/user"].name.get() == "User Directory"
    
    # Add another root
    registry.addRoot("file:///etc")
    check registry.roots.len == 2
    check registry.roots.hasKey("file:///etc")
    check registry.roots["file:///etc"].name.isNone()
    
    # Remove a root
    registry.removeRoot("file:///home/user")
    check registry.roots.len == 1
    check not registry.roots.hasKey("file:///home/user")
    check registry.roots.hasKey("file:///etc")
  
  test "Get roots and root definitions":
    let registry = newRootRegistry()
    
    # Add roots
    registry.addRoot("file:///home/user", some("User Directory"))
    registry.addRoot("file:///etc", some("Configuration Files"))
    registry.addRoot("db://localhost/mydb", some("Database"))
    
    # Get roots as sequence
    let roots = registry.getRoots()
    check roots.len == 3
    
    # Check that all URIs are present
    var uris: seq[string] = @[]
    for root in roots:
      uris.add(root.uri)
    
    check "file:///home/user" in uris
    check "file:///etc" in uris
    check "db://localhost/mydb" in uris
    
    # Get root definitions as JSON
    let rootDefs = registry.getRootDefinitions()
    check rootDefs.kind == JArray
    check rootDefs.len == 3
    
    # Verify that all roots are in the JSON output
    var foundUris: seq[string] = @[]
    for item in rootDefs:
      foundUris.add(item["uri"].getStr())
    
    check "file:///home/user" in foundUris
    check "file:///etc" in foundUris
    check "db://localhost/mydb" in foundUris
  
  test "Root subscriptions":
    let registry = newRootRegistry()
    
    # Add a root
    registry.addRoot("file:///home/user", some("User Directory"))
    
    # Subscribe to the root
    registry.subscribeRoot("file:///home/user", "client1")
    check registry.subscribers.hasKey("file:///home/user")
    check registry.subscribers["file:///home/user"].len == 1
    check registry.subscribers["file:///home/user"][0] == "client1"
    
    # Subscribe again with a different client
    registry.subscribeRoot("file:///home/user", "client2")
    check registry.subscribers["file:///home/user"].len == 2
    check "client1" in registry.subscribers["file:///home/user"]
    check "client2" in registry.subscribers["file:///home/user"]
    
    # Attempt to subscribe to non-existent root
    registry.subscribeRoot("file:///nonexistent", "client1")
    check not registry.subscribers.hasKey("file:///nonexistent")
    
    # Get subscribers
    let subs = registry.getSubscribers("file:///home/user")
    check subs.len == 2
    check "client1" in subs
    check "client2" in subs
    
    # Unsubscribe
    registry.unsubscribeRoot("file:///home/user", "client1")
    check registry.subscribers["file:///home/user"].len == 1
    check "client1" notin registry.subscribers["file:///home/user"]
    check "client2" in registry.subscribers["file:///home/user"]
    
    # Clear all subscriptions for a client
    registry.subscribeRoot("file:///home/user", "client3")
    registry.addRoot("file:///etc")
    registry.subscribeRoot("file:///etc", "client3")
    
    # Verify both subscriptions exist
    check "client3" in registry.subscribers["file:///home/user"]
    check "client3" in registry.subscribers["file:///etc"]
    
    # Clear all for client3
    registry.clearAllSubscriptions("client3")
    
    # Verify client3 is removed from both
    check "client3" notin registry.subscribers["file:///home/user"]
    check not registry.subscribers.hasKey("file:///etc")  # Should be removed completely
  
  test "Root URI validation":
    check isValidRootUri("file:///home/user")
    check isValidRootUri("http://example.com/api")
    check isValidRootUri("db://localhost/mydb")
    
    # Invalid URIs
    check not isValidRootUri("")
    check not isValidRootUri("file:///home user")  # Contains space
  
  test "Root access control":
    let registry = newRootRegistry()
    
    # Add roots
    registry.addRoot("file:///home/user", some("User Directory"))
    registry.addRoot("file:///etc", some("Configuration Files"))
    
    # Check access (basic implementation always returns true for existing roots)
    check registry.hasRootAccess("file:///home/user", "client1")
    check registry.hasRootAccess("file:///etc", "client1")
    
    # Non-existent root should be denied
    check not registry.hasRootAccess("file:///nonexistent", "client1")

# Run the tests
when isMainModule:
  echo "Running tests..."
