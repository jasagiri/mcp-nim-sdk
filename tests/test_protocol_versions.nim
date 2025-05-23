## Protocol version tests for the Model Context Protocol (MCP).
##
## These tests verify the correct handling of different protocol versions, version
## negotiation, and protocol message compatibility between versions.

import unittest
import json
import options
import std/strutils
import ../src/mcp/protocol
import ../src/mcp/types

suite "Protocol Version Tests":
  
  test "MCPVersion string representation":
    # Test version string representation
    let v1 = MCPVersion(kind: VersionDate, version: "2025-03-26")
    let v2 = MCPVersion(kind: VersionSemver, major: 1, minor: 0, patch: 0)
    
    check($v1 == "2025-03-26")
    check($v2 == "1.0.0")
  
  test "Version creation from string":
    # Test creating versions from string
    let v1 = createVersion("2025-03-26")
    let v2 = createVersion("1.0.0")
    
    check(v1.kind == VersionDate)
    check(v1.version == "2025-03-26")
    
    check(v2.kind == VersionSemver)
    check(v2.major == 1)
    check(v2.minor == 0)
    check(v2.patch == 0)
    
    expect ValueError:
      discard createVersion("invalid")
  
  test "Version comparison":
    # Test version comparison operators
    let v1 = MCPVersion(kind: VersionDate, version: "2025-03-26")
    let v2 = MCPVersion(kind: VersionDate, version: "2025-03-27")
    let v3 = MCPVersion(kind: VersionSemver, major: 1, minor: 0, patch: 0)
    let v4 = MCPVersion(kind: VersionSemver, major: 1, minor: 1, patch: 0)
    
    # Same version type comparisons
    check(v1 < v2)
    check(v3 < v4)
    check(v2 > v1)
    check(v4 > v3)
    
    # Different version types - date-based is considered newer than semver
    check(v1 > v3)
    check(v1 > v4)
    check(v2 > v3)
    check(v2 > v4)
    check(v3 < v1)
    check(v4 < v1)
    
    # Equality
    let v5 = MCPVersion(kind: VersionDate, version: "2025-03-26")
    let v6 = MCPVersion(kind: VersionSemver, major: 1, minor: 0, patch: 0)
    
    check(v1 == v5)
    check(v3 == v6)
  
  test "Message serialization with different versions":
    # Test serializing messages with different protocol versions
    let req = RequestMessage(
      id: "req-1",
      methodName: "initialize",
      params: %*{}
    )
    
    let v2025 = MCPVersion(kind: VersionDate, version: "2025-03-26")
    let v2024 = MCPVersion(kind: VersionSemver, major: 1, minor: 0, patch: 0)
    
    let json2025 = serializeWithVersion(req, v2025)
    let json2024 = serializeWithVersion(req, v2024)
    
    # Check 2025-03-26 serialization
    let parsed2025 = parseJson(json2025)
    check(parsed2025.hasKey("method"))
    check(parsed2025["method"].getStr() == "initialize")
    check(parsed2025.hasKey("params"))
    check(parsed2025["params"].hasKey("protocolVersion"))
    check(parsed2025["params"]["protocolVersion"].getStr() == "2025-03-26")
    
    # Check 2024-11-05 serialization
    let parsed2024 = parseJson(json2024)
    check(parsed2024.hasKey("method"))
    check(parsed2024["method"].getStr() == "initialize")
    check(parsed2024.hasKey("params"))
    check(parsed2024["params"].hasKey("protocolVersion"))
    check(parsed2024["params"]["protocolVersion"].hasKey("major"))
    check(parsed2024["params"]["protocolVersion"]["major"].getInt() == 1)
    check(parsed2024["params"]["protocolVersion"]["minor"].getInt() == 0)
    check(parsed2024["params"]["protocolVersion"]["patch"].getInt() == 0)
  
  test "Notification method name handling":
    # Test notification method name differences between versions
    let notif = NotificationMessage(
      methodName: "initialized",
      params: %*{}
    )
    
    let v2025 = MCPVersion(kind: VersionDate, version: "2025-03-26")
    let v2024 = MCPVersion(kind: VersionSemver, major: 1, minor: 0, patch: 0)
    
    let json2025 = serializeWithVersion(notif, v2025)
    let json2024 = serializeWithVersion(notif, v2024)
    
    # Check 2025-03-26 serialization (uses $/initialized)
    let parsed2025 = parseJson(json2025)
    check(parsed2025.hasKey("method"))
    check(parsed2025["method"].getStr() == "$/initialized")
    
    # Check 2024-11-05 serialization (uses initialized)
    let parsed2024 = parseJson(json2024)
    check(parsed2024.hasKey("method"))
    check(parsed2024["method"].getStr() == "initialized")
    
    # Test parsing back
    let parsed2025Notif = parseNotificationWithVersion(json2025, v2025)
    check(parsed2025Notif.methodName == "initialized") # internally normalized
    
    let parsed2024Notif = parseNotificationWithVersion(json2024, v2024)
    check(parsed2024Notif.methodName == "initialized")
  
  test "Basic version negotiation":
    # Simple test just to verify version formatting
    let v2025 = MCPVersion(kind: VersionDate, version: "2025-03-26")
    let v2024 = MCPVersion(kind: VersionSemver, major: 1, minor: 0, patch: 0)
    
    # Verify string representations
    check($v2025 == "2025-03-26")
    check($v2024 == "1.0.0")
    
    # Test initializing a protocol with specific version
    var protocol = newProtocol(v2025)
    check(protocol.version.kind == VersionDate)
    check(protocol.version.version == "2025-03-26")
    
    # Change protocol version
    activateVersion(protocol, v2024)
    check(protocol.version.kind == VersionSemver)
    check(protocol.version.major == 1)
    check(protocol.version.minor == 0)
    check(protocol.version.patch == 0)
    
  test "Message format with version":
    # Test request message format
    let req = RequestMessage(
      id: "req-1",
      methodName: "initialize",
      params: %*{}
    )
    
    # Format with different versions
    let json2025 = serializeWithVersion(req, MCPVersion(kind: VersionDate, version: "2025-03-26"))
    let json2024 = serializeWithVersion(req, MCPVersion(kind: VersionSemver, major: 1, minor: 0, patch: 0))
    
    # Verify different serialization formats
    let parsed2025 = parseJson(json2025)
    let parsed2024 = parseJson(json2024)
    
    check(parsed2025.hasKey("method"))
    check(parsed2024.hasKey("method"))
    
    # Test notification message format
    let notif = NotificationMessage(
      methodName: "initialized",
      params: %*{}
    )
    
    # Format with different versions
    let notifJson2025 = serializeWithVersion(notif, MCPVersion(kind: VersionDate, version: "2025-03-26"))
    let notifJson2024 = serializeWithVersion(notif, MCPVersion(kind: VersionSemver, major: 1, minor: 0, patch: 0))
    
    # Check method name difference
    let parsedNotif2025 = parseJson(notifJson2025)
    let parsedNotif2024 = parseJson(notifJson2024)
    
    check(parsedNotif2025["method"].getStr() == "$/initialized")
    check(parsedNotif2024["method"].getStr() == "initialized")

when isMainModule:
  # Run the tests
  echo "Running protocol version tests..."