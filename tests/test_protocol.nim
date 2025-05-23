# tests/test_protocol.nim
## MCPプロトコル実装のテスト

import unittest
import std/[json, asyncdispatch, options]
import uuids
import ../src/mcp/types
import ../src/mcp/protocol
import ../src/mcp/transport/base as base_transport

suite "Protocol Tests":
  test "Create Protocol Instance":
    let protocol = newProtocol()
    check protocol != nil
    check protocol.version.kind == VersionDate
    check protocol.version.version == CURRENT_VERSION.version
    
  test "Generate Request ID":
    let id1 = $genUUID()
    let id2 = $genUUID()
    check id1 != id2
    
  test "Request Serialization and Parsing":
    # Create a request
    let request = createRequest(
      methodName = "test.method",
      params = %*{"param": "value"},
      id = "test-id"
    )
    
    # Serialize to string
    let serialized = serialize(request)
    
    # Parse back to request
    let parsed = parseRequest(serialized)
    
    # Verify
    check parsed.id == "test-id"
    check parsed.methodName == "test.method"
    check parsed.params["param"].getStr() == "value"
  
  test "Response Serialization and Parsing":
    # Create a success response
    let response = createSuccessResponse("test-id", %*{"result": "success"})
    
    # Serialize to string
    let serialized = serialize(response)
    
    # Parse back to response
    let parsed = parseResponse(serialized)
    
    # Verify
    check parsed.id == "test-id"
    check parsed.result.isSome
    check parsed.result.get()["result"].getStr() == "success"
  
  test "Notification Serialization and Parsing":
    # Create a notification
    let notification = createNotification(
      methodName = "test.notification",
      params = %*{"param": "value"}
    )
    
    # Serialize to string
    let serialized = serialize(notification)
    
    # Parse back to notification
    let parsed = parseNotification(serialized)
    
    # Verify
    check parsed.methodName == "test.notification"
    check parsed.params["param"].getStr() == "value"
    
  test "Request Handler Registration":
    let protocol = newProtocol()
    var handlerCalled = false
    
    # リクエストハンドラを登録
    protocol.setRequestHandler("test.method",
      proc(request: RequestMessage): ResponseMessage {.gcsafe.} =
        handlerCalled = true
        return createSuccessResponse(request.id, %*{"result": "success"})
    )
    
    # ハンドラの呼び出しをテスト（実際のメッセージ処理をシミュレート）
    let request = RequestMessage(
      id: "test-id",
      methodName: "test.method",
      params: %*{"param": "value"}
    )

    # プロトコルのhandleRequestに渡す
    let response = protocol.handleRequest(request)
    
    check handlerCalled

    # レスポンスの内容を確認
    check response.id == "test-id"
    check response.result.isSome
    check response.result.get()["result"].getStr() == "success"
  
  test "Notification Handler Registration":
    let protocol = newProtocol()
    var handlerCalled = false
    
    # 通知ハンドラを登録
    protocol.setNotificationHandler("test.notification",
      proc(notification: NotificationMessage) {.gcsafe.} =
        handlerCalled = true
    )
    
    # ハンドラの呼び出しをテスト
    let notification = NotificationMessage(
      methodName: "test.notification",
      params: %*{"param": "value"}
    )
    
    # プロトコルのhandleNotificationに渡す
    protocol.handleNotification(notification)
    
    check handlerCalled
  
  test "Request Method Not Found":
    let protocol = newProtocol()
    
    # 未登録のメソッドをリクエスト
    let request = RequestMessage(
      id: "test-id",
      methodName: "unknown.method",
      params: %*{"param": "value"}
    )
    
    # プロトコルのhandleRequestに渡す
    let response = protocol.handleRequest(request)
    
    # レスポンスがエラーになっていることを確認
    check response.id == "test-id"
    check response.error.isSome
    check response.error.get().code == ERR_METHOD_NOT_FOUND
  
  test "Error Response Creation":
    let errorResponse = createErrorResponse("test-id", ERR_INVALID_PARAMS, "Invalid parameters")
    check errorResponse.id == "test-id"
    check errorResponse.error.isSome
    check errorResponse.error.get().code == ERR_INVALID_PARAMS
    check errorResponse.error.get().message == "Invalid parameters"
  
  test "Version-specific serialization":
    # Create a request
    let request = createRequest(
      methodName = "test.method",
      params = %*{"param": "value"},
      id = "test-id"
    )
    
    # Define a test version
    let testVersion = MCPVersion(
      kind: VersionDate,
      version: "2025-03-26"
    )
    
    # Serialize with specific version
    let serialized = serializeWithVersion(request, testVersion)
    
    # Parse back with specific version
    let parsed = parseRequestWithVersion(serialized, testVersion)
    
    # Verify
    check parsed.id == "test-id"
    check parsed.methodName == "test.method"
    check parsed.params["param"].getStr() == "value"
  
  test "JSON-RPC message type detection":
    # Request
    let requestMsg = """{"jsonrpc": "2.0", "method": "test.method", "params": {}, "id": "1"}"""
    let requestType = base_transport.parseJsonRpc(requestMsg)
    check requestType.isRequest
    check not requestType.isResponse
    check not requestType.isNotification
    
    # Response
    let responseMsg = """{"jsonrpc": "2.0", "result": {}, "id": "1"}"""
    let responseType = base_transport.parseJsonRpc(responseMsg)
    check not responseType.isRequest
    check responseType.isResponse
    check not responseType.isNotification
    
    # Notification
    let notificationMsg = """{"jsonrpc": "2.0", "method": "test.notification", "params": {}}"""
    let notificationType = base_transport.parseJsonRpc(notificationMsg)
    check not notificationType.isRequest
    check not notificationType.isResponse
    check notificationType.isNotification
