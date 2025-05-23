# Model Context Protocol (MCP) Server SDK for Nim
#
# Tests for the MCP prompts implementation.

import unittest, json, asyncdispatch, options, strutils
import ../src/mcp/prompts
import ../src/mcp/types

suite "Prompt Registry Tests":
  setup:
    let registry = newPromptRegistry()
  
  test "Prompt type registration and retrieval":
    # Register a prompt type
    registry.registerPromptType(
      "simple_question",
      "A simple question prompt",
      %*{
        "type": "object",
        "properties": {
          "question": {"type": "string"},
          "context": {"type": "string"}
        },
        "required": ["question"]
      }
    )
    
    # Get prompt type definitions
    let definitions = registry.getPromptTypeDefinitions()
    
    check(definitions.len == 1)
    check(definitions[0]["name"].getStr() == "simple_question")
    check(definitions[0]["description"].getStr() == "A simple question prompt")
    check(definitions[0]["paramsSchema"].kind == JObject)
    check(definitions[0]["paramsSchema"]["properties"]["question"]["type"].getStr() == "string")
    check(definitions[0]["paramsSchema"]["properties"]["context"]["type"].getStr() == "string")
    check(definitions[0]["paramsSchema"]["required"][0].getStr() == "question")
  
  test "Multiple prompt type registration":
    # Register multiple prompt types
    registry.registerPromptType(
      "simple_question",
      "A simple question prompt",
      %*{
        "type": "object",
        "properties": {
          "question": {"type": "string"}
        },
        "required": ["question"]
      }
    )
    
    registry.registerPromptType(
      "summarization",
      "A summarization prompt",
      %*{
        "type": "object",
        "properties": {
          "text": {"type": "string"},
          "max_length": {"type": "integer"}
        },
        "required": ["text"]
      }
    )
    
    # Get prompt type definitions
    let definitions = registry.getPromptTypeDefinitions()
    
    check(definitions.len == 2)
    
    # Find definitions for each type
    var questionDef, summarizationDef: JsonNode
    for def in definitions:
      if def["name"].getStr() == "simple_question":
        questionDef = def
      elif def["name"].getStr() == "summarization":
        summarizationDef = def
    
    check(questionDef != nil)
    check(summarizationDef != nil)
    
    check(questionDef["description"].getStr() == "A simple question prompt")
    check(summarizationDef["description"].getStr() == "A summarization prompt")
    
    check(questionDef["paramsSchema"]["required"][0].getStr() == "question")
    check(summarizationDef["paramsSchema"]["properties"]["max_length"]["type"].getStr() == "integer")

suite "Prompt Parameter Validation Tests":
  test "Valid parameters validation":
    let schema = %*{
      "type": "object",
      "properties": {
        "question": {"type": "string"},
        "max_length": {"type": "integer"},
        "temperature": {"type": "number"}
      },
      "required": ["question"]
    }
    
    let params = %*{
      "question": "What is MCP?",
      "max_length": 100,
      "temperature": 0.7
    }
    
    let (valid, errors) = validatePromptParams(schema, params)
    
    check(valid == true)
    check(errors.len == 0)
  
  test "Missing required parameters validation":
    let schema = %*{
      "type": "object",
      "properties": {
        "question": {"type": "string"},
        "context": {"type": "string"}
      },
      "required": ["question", "context"]
    }
    
    let params = %*{
      "question": "What is MCP?"
    }
    
    let (valid, errors) = validatePromptParams(schema, params)
    
    check(valid == false)
    check(errors.len == 1)
    check(errors[0].contains("context"))
  
  test "Type mismatch validation":
    let schema = %*{
      "type": "object",
      "properties": {
        "question": {"type": "string"},
        "max_tokens": {"type": "integer"},
        "temperature": {"type": "number"},
        "include_references": {"type": "boolean"}
      },
      "required": ["question"]
    }
    
    let params = %*{
      "question": "What is MCP?",
      "max_tokens": "100", # Should be integer
      "temperature": true, # Should be number
      "include_references": 1 # Should be boolean
    }
    
    let (valid, errors) = validatePromptParams(schema, params)
    
    check(valid == false)
    check(errors.len == 3)
    check(errors[0].contains("max_tokens") and errors[0].contains("integer"))
    check(errors[1].contains("temperature") and errors[1].contains("number"))
    check(errors[2].contains("include_references") and errors[2].contains("boolean"))

suite "Prompt Generation Tests":
  test "Simple prompt message generation":
    let promptType = "test_prompt"
    let params = %*{
      "question": "What is MCP?",
      "context": "Model Context Protocol"
    }
    
    let messages = createPromptMessages(promptType, params)
    
    check(messages.len == 1)
    check(messages[0]["role"].getStr() == "user")
    check(messages[0]["content"]["type"].getStr() == "text")
    check(messages[0]["content"]["text"].getStr().contains(promptType))
    check(messages[0]["content"]["text"].getStr().contains("What is MCP?"))
    check(messages[0]["content"]["text"].getStr().contains("Model Context Protocol"))
