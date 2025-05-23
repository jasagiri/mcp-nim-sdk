# Model Context Protocol (MCP) Server SDK for Nim
#
# Tests for the MCP sampling implementation.

import unittest, json, asyncdispatch, options
import ../src/mcp/sampling

# Comment out this section to run the tests
# echo "Skipping sampling tests (needs more implementation work)"
# quit(0)

suite "Message Tests":
  test "Creating text message":
    let msg = newTextMessage(User, "Hello, world!")
    
    check(msg.role == User)
    check(msg.content.len == 1)
    check(msg.content[0].contentType == TextContent)
    check(msg.content[0].text == "Hello, world!")
  
  test "Creating image message":
    let msg = newImageMessage(Assistant, "base64data", "image/png")
    
    check(msg.role == Assistant)
    check(msg.content.len == 1)
    check(msg.content[0].contentType == ImageContent)
    check(msg.content[0].data == "base64data")
    check(msg.content[0].mimeType == "image/png")
  
  test "Adding content to a message":
    var msg = newTextMessage(User, "Hello")
    
    msg.addTextContent("How are you?")
    msg.addImageContent("base64data", "image/jpeg")
    
    check(msg.content.len == 3)
    check(msg.content[0].contentType == TextContent)
    check(msg.content[0].text == "Hello")
    check(msg.content[1].contentType == TextContent)
    check(msg.content[1].text == "How are you?")
    check(msg.content[2].contentType == ImageContent)
    check(msg.content[2].data == "base64data")
    check(msg.content[2].mimeType == "image/jpeg")

suite "JSON Conversion Tests":
  test "Message to JSON":
    let msg = newTextMessage(User, "Hello, world!")
    let jsonMsg = messageToJson(msg)
    
    check(jsonMsg["role"].getStr() == "user")
    check(jsonMsg["content"].len == 1)
    check(jsonMsg["content"][0]["type"].getStr() == "text")
    check(jsonMsg["content"][0]["text"].getStr() == "Hello, world!")
  
  test "Model preferences to JSON":
    let prefs = newModelPreferences(
      hints = @["model1", "model2"],
      costPriority = some(0.5),
      speedPriority = some(0.8),
      intelligencePriority = none(float)
    )
    
    let jsonPrefs = modelPreferencesToJson(prefs)
    
    check(jsonPrefs.hasKey("hints"))
    check(jsonPrefs["hints"].len == 2)
    check(jsonPrefs["hints"][0]["name"].getStr() == "model1")
    check(jsonPrefs["hints"][1]["name"].getStr() == "model2")
    check(jsonPrefs["costPriority"].getFloat() == 0.5)
    check(jsonPrefs["speedPriority"].getFloat() == 0.8)
    check(not jsonPrefs.hasKey("intelligencePriority"))
  
  test "Sampling request to JSON":
    let req = newSamplingRequest(
      messages = @[newTextMessage(User, "Hello, world!")],
      maxTokens = 100,
      systemPrompt = some("You are a helpful assistant."),
      temperature = some(0.7),
      stopSequences = @["STOP", "."],
      includeContext = ThisServer
    )
    
    let jsonReq = samplingRequestToJson(req)
    
    check(jsonReq["messages"].len == 1)
    check(jsonReq["maxTokens"].getInt() == 100)
    check(jsonReq["systemPrompt"].getStr() == "You are a helpful assistant.")
    check(jsonReq["temperature"].getFloat() == 0.7)
    check(jsonReq["stopSequences"].len == 2)
    check(jsonReq["stopSequences"][0].getStr() == "STOP")
    check(jsonReq["stopSequences"][1].getStr() == ".")
    check(jsonReq["includeContext"].getStr() == "thisServer")

suite "Parsing Tests":
  test "Parse message content":
    let jsonTextContent = %*{
      "type": "text",
      "text": "Hello, world!"
    }

    let textContent = parseMessageContent(jsonTextContent)
    check(textContent.contentType == TextContent)
    check(textContent.text == "Hello, world!")

    let jsonImageContent = %*{
      "type": "image",
      "data": "base64data",
      "mimeType": "image/png"
    }

    let imageContent = parseMessageContent(jsonImageContent)
    check(imageContent.contentType == ImageContent)
    check(imageContent.data == "base64data")
    check(imageContent.mimeType == "image/png")

  test "Parse malformed message content":
    # Missing type field
    let missingType = %*{
      "text": "Hello, world!"
    }

    let missingTypeContent = parseMessageContent(missingType)
    check(missingTypeContent.contentType == TextContent)
    check(missingTypeContent.text == "Hello, world!")

    # Missing required image fields
    let missingImageData = %*{
      "type": "image"
    }

    let missingImageDataContent = parseMessageContent(missingImageData)
    check(missingImageDataContent.contentType == TextContent)
    check(missingImageDataContent.text == "")

    # Unknown content type
    let unknownType = %*{
      "type": "unknown",
      "text": "Hello, world!"
    }

    let unknownTypeContent = parseMessageContent(unknownType)
    check(unknownTypeContent.contentType == TextContent)
    check(unknownTypeContent.text == "Hello, world!")
  
  test "Parse message":
    let jsonMsg = %*{
      "role": "user",
      "content": [
        {
          "type": "text",
          "text": "Hello, world!"
        },
        {
          "type": "image",
          "data": "base64data",
          "mimeType": "image/png"
        }
      ]
    }

    let msg = parseMessage(jsonMsg)
    check(msg.role == User)
    check(msg.content.len == 2)
    check(msg.content[0].contentType == TextContent)
    check(msg.content[0].text == "Hello, world!")
    check(msg.content[1].contentType == ImageContent)
    check(msg.content[1].data == "base64data")
    check(msg.content[1].mimeType == "image/png")

  test "Parse malformed message":
    # Missing role field
    let missingRole = %*{
      "content": [
        {
          "type": "text",
          "text": "Hello, world!"
        }
      ]
    }

    let missingRoleMsg = parseMessage(missingRole)
    check(missingRoleMsg.role == User)  # Default to User
    check(missingRoleMsg.content.len == 1)

    # Unknown role
    let unknownRole = %*{
      "role": "system",
      "content": [
        {
          "type": "text",
          "text": "Hello, world!"
        }
      ]
    }

    let unknownRoleMsg = parseMessage(unknownRole)
    check(unknownRoleMsg.role == User)  # Default to User
    check(unknownRoleMsg.content.len == 1)

    # Single content object instead of array
    let singleContent = %*{
      "role": "assistant",
      "content": {
        "type": "text",
        "text": "Hello, world!"
      }
    }

    let singleContentMsg = parseMessage(singleContent)
    check(singleContentMsg.role == Assistant)
    check(singleContentMsg.content.len == 1)
    check(singleContentMsg.content[0].contentType == TextContent)
    check(singleContentMsg.content[0].text == "Hello, world!")
  
  test "Parse sampling response":
    let jsonResp = %*{
      "model": "gpt-4",
      "stopReason": "endTurn",
      "role": "assistant",
      "content": [
        {
          "type": "text",
          "text": "I'm an AI assistant."
        }
      ]
    }

    let resp = parseSamplingResponse(jsonResp)
    check(resp.model == "gpt-4")
    check(resp.stopReason.isSome)
    check(resp.stopReason.get() == EndTurn)
    check(resp.role == Assistant)
    check(resp.content.len == 1)
    check(resp.content[0].contentType == TextContent)
    check(resp.content[0].text == "I'm an AI assistant.")

  test "Parse malformed sampling response":
    # Different format for stop reason
    let differentStop = %*{
      "model": "gpt-4",
      "stopReason": "end_turn",
      "role": "assistant",
      "content": {
        "type": "text",
        "text": "I'm an AI assistant."
      }
    }

    let differentStopResp = parseSamplingResponse(differentStop)
    check(differentStopResp.stopReason.isSome)
    check(differentStopResp.stopReason.get() == EndTurn)
    check(differentStopResp.content.len == 1)

    # Missing stop reason
    let missingStop = %*{
      "model": "gpt-4",
      "role": "assistant",
      "content": {
        "type": "text",
        "text": "I'm an AI assistant."
      }
    }

    let missingStopResp = parseSamplingResponse(missingStop)
    check(missingStopResp.stopReason.isNone)
    check(missingStopResp.content.len == 1)

    # Unknown role
    let unknownRole = %*{
      "model": "gpt-4",
      "stopReason": "maxTokens",
      "role": "system",
      "content": {
        "type": "text",
        "text": "I'm an AI assistant."
      }
    }

    let unknownRoleResp = parseSamplingResponse(unknownRole)
    check(unknownRoleResp.stopReason.isSome)
    check(unknownRoleResp.stopReason.get() == MaxTokens)
    check(unknownRoleResp.role == Assistant)  # Default to Assistant

suite "Sampling Manager Tests":
  setup:
    var samplingManager = newSamplingManager()
    
    # Mock create message function
    samplingManager.createMessageFn = proc(request: JsonNode): Future[JsonNode] {.async.} =
      return %*{
        "model": "test-model",
        "role": "assistant",
        "content": [
          {
            "type": "text",
            "text": "I'm a test response"
          }
        ]
      }
  
  test "Create message":
    let messages = @[
      %*{
        "role": "user",
        "content": {
          "type": "text",
          "text": "Hello, world!"
        }
      }
    ]
    
    let response = waitFor samplingManager.createMessage(
      messages = messages,
      systemPrompt = some("You are a test assistant"),
      maxTokens = 50
    )
    
    check(response["model"].getStr() == "test-model")
    check(response["role"].getStr() == "assistant")
    check(response["content"].len == 1)
    check(response["content"][0]["type"].getStr() == "text")
    check(response["content"][0]["text"].getStr() == "I'm a test response")