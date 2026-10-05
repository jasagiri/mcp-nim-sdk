## The client answers elicitation/create (2025-06-18 to 2025-11-25): it
## declares what it can do, hands the request to the application, and checks
## what the application answers before the server sees it.

import std/[unittest, asyncdispatch, json]
import client/client
import client/elicitation
import protocol/types
import ./client_peer

proc responseTo(peer: Peer, id: string): JsonNode =
  waitFor sleepAsync(5)
  for message in peer.received:
    if message.hasKey("id") and not message.hasKey("method") and message["id"].getStr() == id:
      return message
  nil

let
  schema = %*{"type": "object",
              "properties": {"name": {"type": "string"}, "age": {"type": "integer", "minimum": 18}},
              "required": ["name"]}
  formParams = %*{"message": "Who are you?", "requestedSchema": schema}

proc answering(action: ElicitAction, content: JsonNode = nil): McpElicitationHandler =
  result = proc(request: McpElicitRequest): Future[McpElicitResult] {.async.} =
    return McpElicitResult(action: action, content: content)

if LegacyDefault >= mpv20250618:
  suite "elicitation answered by the client":

    test "Given an elicitation handler, when the client connects, then initialize declares the form mode":
      let peer = startPeer(nil)
      discard peer.connectedClient(LegacyDefault, proc(client: McpClient) =
        client.setElicitationHandler(answering(eaCancel)))
      check peer.requestsFor("initialize")[0]["params"]["capabilities"]["elicitation"] ==
        %*{"form": {}}

    test "Given an accepting handler, when the server asks, then the handler sees the request and the answer is sent in wire form":
      var seen: McpElicitRequest
      let peer = startPeer(nil)
      discard peer.connectedClient(LegacyDefault, proc(client: McpClient) =
        client.setElicitationHandler(proc(request: McpElicitRequest): Future[McpElicitResult] {.async.} =
          seen = request
          return McpElicitResult(action: eaAccept, content: %*{"name": "Mona", "age": 30})))
      peer.ask(%"e1", "elicitation/create", formParams)
      check peer.responseTo("e1")["result"] ==
        %*{"action": "accept", "content": {"name": "Mona", "age": 30}}
      check seen.mode == emForm
      check seen.message == "Who are you?"
      check seen.requestedSchema == schema

    test "Given a handler that declines or cancels, when the server asks, then the result has the action and no content":
      for action in [eaDecline, eaCancel]:
        let peer = startPeer(nil)
        discard peer.connectedClient(LegacyDefault, proc(client: McpClient) =
          client.setElicitationHandler(answering(action)))
        peer.ask(%"e1", "elicitation/create", formParams)
        check peer.responseTo("e1")["result"] == %*{"action": $action}

    test "Given a handler whose content does not match the schema, when the server asks, then the server gets an internal error and not the content":
      let peer = startPeer(nil)
      discard peer.connectedClient(LegacyDefault, proc(client: McpClient) =
        client.setElicitationHandler(answering(eaAccept, %*{"age": 12})))
      peer.ask(%"e1", "elicitation/create", formParams)
      let reply = peer.responseTo("e1")
      check reply.hasKey("error")
      check reply["error"]["code"].getInt() == -32603
      check not reply.hasKey("result")

    test "Given a request whose schema breaks the rules, when it arrives, then the client answers invalid params and the handler is not called":
      var called = false
      let peer = startPeer(nil)
      discard peer.connectedClient(LegacyDefault, proc(client: McpClient) =
        client.setElicitationHandler(proc(request: McpElicitRequest): Future[McpElicitResult] {.async.} =
          called = true))
      peer.ask(%"e1", "elicitation/create", %*{"message": "m", "requestedSchema": {
        "type": "object", "properties": {"nested": {"type": "object"}}}})
      check peer.responseTo("e1")["error"]["code"].getInt() == -32602
      check not called

    test "Given no elicitation handler, when the server asks, then the client answers method not found":
      let peer = startPeer(nil)
      discard peer.connectedClient(LegacyDefault)
      peer.ask(%"e1", "elicitation/create", formParams)
      check peer.responseTo("e1")["error"]["code"].getInt() == -32601

    test "Given a handler that refuses with McpRequestError, when the server asks, then the server gets that error":
      let peer = startPeer(nil)
      discard peer.connectedClient(LegacyDefault, proc(client: McpClient) =
        client.setElicitationHandler(proc(request: McpElicitRequest): Future[McpElicitResult] {.async.} =
          var refusal = newException(McpRequestError, "not now")
          refusal.code = -1
          raise refusal))
      peer.ask(%"e1", "elicitation/create", formParams)
      check peer.responseTo("e1")["error"]["code"].getInt() == -1

    test "Given a connection of a version before elicitation, when the server asks, then the client answers method not found":
      let peer = startPeer(nil)
      discard peer.connectedClient(mpv20250326, proc(client: McpClient) =
        client.setElicitationHandler(answering(eaCancel)))
      peer.ask(%"e1", "elicitation/create", formParams)
      check peer.responseTo("e1")["error"]["code"].getInt() == -32601

    test "Given a connected client, when a handler is set, then it raises because capabilities are declared in the handshake":
      let peer = startPeer(nil)
      let client = peer.connectedClient(LegacyDefault)
      expect McpError:
        client.setElicitationHandler(answering(eaCancel))

if LegacyDefault >= mpv20251125:
  suite "elicitation answered by the client: enum schemas (2025-11-25)":

    let titled = %*{"message": "Pick", "requestedSchema": {"type": "object", "properties": {
      "colour": {"type": "string", "oneOf": [{"const": "#f00", "title": "Red"}], "default": "#f00"}}}}

    test "Given a connection of 2025-11-25, when the server asks for a titled enum, then the handler is called and its answer is checked against the options":
      var called = false
      let peer = startPeer(nil)
      discard peer.connectedClient(mpv20251125, proc(client: McpClient) =
        client.setElicitationHandler(proc(request: McpElicitRequest): Future[McpElicitResult] {.async.} =
          called = true
          return McpElicitResult(action: eaAccept, content: %*{"colour": "#f00"})))
      peer.ask(%"e1", "elicitation/create", titled)
      check peer.responseTo("e1")["result"]["content"]["colour"].getStr() == "#f00"
      check called

    test "Given a connection of 2025-06-18, when the server asks for a titled enum, then the client answers invalid params":
      let peer = startPeer(nil)
      discard peer.connectedClient(mpv20250618, proc(client: McpClient) =
        client.setElicitationHandler(answering(eaCancel)))
      peer.ask(%"e1", "elicitation/create", titled)
      check peer.responseTo("e1")["error"]["code"].getInt() == -32602
