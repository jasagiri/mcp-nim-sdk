# Model Context Protocol (MCP) Server SDK for Nim
#
# Tests for the MCP tools implementation.

import unittest, json, asyncdispatch, options
import ../src/mcp/tools
# Import the types module as it may be used by compiler-generated code
import ../src/mcp/types

suite "Tool Registry Tests":
  setup:
    let registry = newToolRegistry()
  
  test "Tool registration and retrieval":
    # Register a tool
    registry.registerTool(
      "echo",
      "Echo back the input",
      %*{
        "type": "object",
        "properties": {
          "message": {"type": "string"}
        },
        "required": ["message"]
      },
      proc(args: JsonNode): Future[JsonNode] {.async.} =
        let message = args["message"].getStr()
        return %*{"message": message}
    )
    
    # Get tool definitions
    let definitions = registry.getToolDefinitions()
    
    check(definitions.len == 1)
    check(definitions[0]["name"].getStr() == "echo")
    check(definitions[0]["description"].getStr() == "Echo back the input")
    check(definitions[0]["inputSchema"].kind == JObject)
    check(definitions[0]["inputSchema"]["properties"]["message"]["type"].getStr() == "string")
    
    # Execute the tool
    let args = %*{"message": "Hello, world!"}
    let result = waitFor registry.executeTool("echo", args)
    
    check(result.isSome)
    check(result.get()["message"].getStr() == "Hello, world!")
  
  test "Multiple tool registration":
    # Register tools
    registry.registerTool(
      "add",
      "Add two numbers",
      %*{
        "type": "object",
        "properties": {
          "a": {"type": "number"},
          "b": {"type": "number"}
        },
        "required": ["a", "b"]
      },
      proc(args: JsonNode): Future[JsonNode] {.async.} =
        let a = args["a"].getFloat()
        let b = args["b"].getFloat()
        return %*(a + b)
    )
    
    registry.registerTool(
      "subtract",
      "Subtract two numbers",
      %*{
        "type": "object",
        "properties": {
          "a": {"type": "number"},
          "b": {"type": "number"}
        },
        "required": ["a", "b"]
      },
      proc(args: JsonNode): Future[JsonNode] {.async.} =
        let a = args["a"].getFloat()
        let b = args["b"].getFloat()
        return %*(a - b)
    )
    
    # Get tool definitions
    let definitions = registry.getToolDefinitions()
    
    check(definitions.len == 2)
    
    # Execute the tools
    let addArgs = %*{"a": 5, "b": 3}
    let addResult = waitFor registry.executeTool("add", addArgs)
    
    check(addResult.isSome)
    check(addResult.get().getFloat() == 8.0)
    
    let subtractArgs = %*{"a": 5, "b": 3}
    let subtractResult = waitFor registry.executeTool("subtract", subtractArgs)
    
    check(subtractResult.isSome)
    check(subtractResult.get().getFloat() == 2.0)
  
  test "Unknown tool execution":
    let result = waitFor registry.executeTool("unknown", %*{})
    check(result.isNone)
  
  test "Tool error handling":
    # Register a tool that might throw an error
    registry.registerTool(
      "divide",
      "Divide two numbers",
      %*{
        "type": "object",
        "properties": {
          "a": {"type": "number"},
          "b": {"type": "number"}
        },
        "required": ["a", "b"]
      },
      proc(args: JsonNode): Future[JsonNode] {.async.} =
        let a = args["a"].getFloat()
        let b = args["b"].getFloat()

        if b == 0:
          # Return an error instead of raising an exception
          return newToolError("Division by zero")

        return %*(a / b)
    )

    # Execute with valid arguments
    let validArgs = %*{"a": 10, "b": 2}
    let validResult = waitFor registry.executeTool("divide", validArgs)

    check(validResult.isSome)
    check(validResult.get().getFloat() == 5.0)

    # Execute with invalid arguments
    let invalidArgs = %*{"a": 10, "b": 0}
    let invalidResult = waitFor registry.executeTool("divide", invalidArgs)

    check(invalidResult.isSome)
    check(invalidResult.get()["isError"].getBool() == true)
    check(invalidResult.get()["content"][0]["text"].getStr() == "Division by zero")

  test "Tool registration with ToolConfig object":
    # Create a tool config
    let config = ToolConfig(
      name: "multiply",
      description: "Multiply two numbers",
      inputSchema: %*{
        "type": "object",
        "properties": {
          "a": {"type": "number"},
          "b": {"type": "number"}
        },
        "required": ["a", "b"]
      },
      handler: proc(args: JsonNode): Future[JsonNode] {.async.} =
        let a = args["a"].getFloat()
        let b = args["b"].getFloat()
        return %*(a * b)
    )
    
    # Test the newToolConfig function explicitly
    let newConfig = newToolConfig(
      "multiply2",
      "Multiply two numbers (alternative)",
      %*{
        "type": "object",
        "properties": {
          "a": {"type": "number"},
          "b": {"type": "number"}
        }
      }
    )
    
    check(newConfig.name == "multiply2")
    check(newConfig.description == "Multiply two numbers (alternative)")
    
    # Register using the overloaded method
    registry.registerTool(config)
    
    # Execute the tool
    let args = %*{"a": 4, "b": 5}
    let result = waitFor registry.executeTool("multiply", args)
    
    check(result.isSome)
    check(result.get().getFloat() == 20.0)

  test "Tool execution with invalid arguments":
    # Register a tool with validation
    registry.registerTool(
      "validate_test",
      "Test argument validation",
      %*{
        "type": "object",
        "properties": {
          "name": {"type": "string"},
          "age": {"type": "number"}
        },
        "required": ["name", "age"]
      },
      proc(args: JsonNode): Future[JsonNode] {.async.} =
        return %*{"result": "valid"}
    )
    
    # Missing required arg
    let missingArg = %*{"name": "Test"}
    let missingResult = waitFor registry.executeTool("validate_test", missingArg)
    check(missingResult.isNone)
    
    # Wrong type
    let wrongType = %*{"name": "Test", "age": "thirty"}
    let wrongTypeResult = waitFor registry.executeTool("validate_test", wrongType)
    check(wrongTypeResult.isNone)
    
    # Valid args
    let validArgs = %*{"name": "Test", "age": 30}
    let validResult = waitFor registry.executeTool("validate_test", validArgs)
    check(validResult.isSome)
    check(validResult.get()["result"].getStr() == "valid")

  test "Tool execution with exception in handler":
    # Register a tool that will throw an exception
    registry.registerTool(
      "exception_tool",
      "Tool that throws an exception",
      %*{
        "type": "object",
        "properties": {
          "input": {"type": "string"}
        },
        "required": ["input"]
      },
      proc(args: JsonNode): Future[JsonNode] {.async.} =
        raise newException(ValueError, "Test exception")
        return %*{}  # unreachable
    )
    
    # Execute the tool
    let args = %*{"input": "test"}
    let result = waitFor registry.executeTool("exception_tool", args)
    
    # Should return none because the handler threw an exception
    check(result.isNone)

suite "Tool Schema Validation Tests":
  test "validateToolArguments basic cases":
    # Valid schema and matching args
    let schema = %*{
      "type": "object",
      "properties": {
        "name": {"type": "string"},
        "age": {"type": "number"},
        "isActive": {"type": "boolean"}
      },
      "required": ["name", "age"]
    }
    
    let validArgs = %*{
      "name": "John",
      "age": 30,
      "isActive": true
    }
    
    check(validateToolArguments(schema, validArgs) == true)
    
    # Missing required property
    let missingRequired = %*{
      "name": "John"
    }
    
    check(validateToolArguments(schema, missingRequired) == false)
    
    # Test with an explicitly missing required property to increase coverage
    let schemaWithReq = %*{
      "type": "object",
      "properties": {
        "requiredProp": {"type": "string"}
      },
      "required": ["requiredProp"]
    }
    let missingReqProp = %*{"otherProp": "value"}
    check(validateToolArguments(schemaWithReq, missingReqProp) == false)
    
    # Wrong property type
    let wrongType = %*{
      "name": "John",
      "age": "thirty"
    }
    
    check(validateToolArguments(schema, wrongType) == false)
    
    # Non-object schema
    let nonObjectSchema = %*{
      "type": "string"
    }
    
    check(validateToolArguments(nonObjectSchema, validArgs) == false)
    
    # Test specific type validations
    let typesSchema = %*{
      "type": "object",
      "properties": {
        "string_prop": {"type": "string"},
        "number_prop": {"type": "number"},
        "integer_prop": {"type": "integer"},
        "boolean_prop": {"type": "boolean"},
        "array_prop": {"type": "array"},
        "object_prop": {"type": "object"},
        "null_prop": {"type": "null"}
      }
    }
    
    # Test string validation
    let invalidStringArgs = %*{"string_prop": 123}
    check(validateToolArguments(typesSchema, invalidStringArgs) == false)
    
    # Test integer validation
    let invalidIntegerArgs = %*{"integer_prop": 3.14}
    check(validateToolArguments(typesSchema, invalidIntegerArgs) == false)
    
    # Test boolean validation
    let invalidBooleanArgs = %*{"boolean_prop": "true"}
    check(validateToolArguments(typesSchema, invalidBooleanArgs) == false)
    
    # Test array validation
    let invalidArrayArgs = %*{"array_prop": "not an array"}
    check(validateToolArguments(typesSchema, invalidArrayArgs) == false)
    
    # Test object validation
    let invalidObjectArgs = %*{"object_prop": [1, 2, 3]}
    check(validateToolArguments(typesSchema, invalidObjectArgs) == false)
    
    # Test null validation
    let invalidNullArgs = %*{"null_prop": 0}
    check(validateToolArguments(typesSchema, invalidNullArgs) == false)

  test "validateToolArguments type checking":
    # Test validation of different types
    let schema = %*{
      "type": "object",
      "properties": {
        "string_val": {"type": "string"},
        "number_val": {"type": "number"},
        "integer_val": {"type": "integer"},
        "boolean_val": {"type": "boolean"},
        "array_val": {"type": "array"},
        "object_val": {"type": "object"},
        "null_val": {"type": "null"}
      }
    }
    
    # Valid args with all correct types
    let validArgs = %*{
      "string_val": "text",
      "number_val": 3.14,
      "integer_val": 42,
      "boolean_val": true,
      "array_val": [1, 2, 3],
      "object_val": {"key": "value"},
      "null_val": newJNull()
    }
    
    check(validateToolArguments(schema, validArgs) == true)
    
    # Test each type with incorrect value
    var invalidStringArgs = copy(validArgs)
    invalidStringArgs["string_val"] = %123
    check(validateToolArguments(schema, invalidStringArgs) == false)
    
    var invalidNumberArgs = copy(validArgs)
    invalidNumberArgs["number_val"] = %"not a number"
    check(validateToolArguments(schema, invalidNumberArgs) == false)
    
    var invalidIntegerArgs = copy(validArgs)
    invalidIntegerArgs["integer_val"] = %3.14
    check(validateToolArguments(schema, invalidIntegerArgs) == false)
    
    var invalidBooleanArgs = copy(validArgs)
    invalidBooleanArgs["boolean_val"] = %"true"
    check(validateToolArguments(schema, invalidBooleanArgs) == false)
    
    var invalidArrayArgs = copy(validArgs)
    invalidArrayArgs["array_val"] = %"not an array"
    check(validateToolArguments(schema, invalidArrayArgs) == false)
    
    var invalidObjectArgs = copy(validArgs)
    invalidObjectArgs["object_val"] = %[1, 2, 3]
    check(validateToolArguments(schema, invalidObjectArgs) == false)
    
    var invalidNullArgs = copy(validArgs)
    invalidNullArgs["null_val"] = %0  # Using int instead of null
    check(validateToolArguments(schema, invalidNullArgs) == false)

suite "Tool Schema Creation Tests":
  test "createBasicSchemaForStringParam":
    # Create schema with required param
    let requiredSchema = createBasicSchemaForStringParam("name", "User's name", true)
    
    check(requiredSchema["type"].getStr() == "object")
    check(requiredSchema["properties"]["name"]["type"].getStr() == "string")
    check(requiredSchema["properties"]["name"]["description"].getStr() == "User's name")
    check(requiredSchema.hasKey("required"))
    check(requiredSchema["required"][0].getStr() == "name")
    
    # Create schema with optional param
    let optionalSchema = createBasicSchemaForStringParam("name", "User's name", false)
    
    check(optionalSchema["type"].getStr() == "object")
    check(optionalSchema["properties"]["name"]["type"].getStr() == "string")
    check(optionalSchema["properties"]["name"]["description"].getStr() == "User's name")
    check(not optionalSchema.hasKey("required"))
  
  test "createBasicSchemaForNumberParam":
    # Create schema with required param
    let requiredSchema = createBasicSchemaForNumberParam("age", "User's age", true)
    
    check(requiredSchema["type"].getStr() == "object")
    check(requiredSchema["properties"]["age"]["type"].getStr() == "number")
    check(requiredSchema["properties"]["age"]["description"].getStr() == "User's age")
    check(requiredSchema.hasKey("required"))
    check(requiredSchema["required"][0].getStr() == "age")
    
    # Create schema with optional param
    let optionalSchema = createBasicSchemaForNumberParam("age", "User's age", false)
    
    check(optionalSchema["type"].getStr() == "object")
    check(optionalSchema["properties"]["age"]["type"].getStr() == "number")
    check(optionalSchema["properties"]["age"]["description"].getStr() == "User's age")
    check(not optionalSchema.hasKey("required"))
  
  test "createBasicSchemaForObjectParam":
    # Create nested properties
    let addressProps = %*{
      "street": {"type": "string"},
      "city": {"type": "string"}
    }
    
    # Create schema with required param
    let requiredSchema = createBasicSchemaForObjectParam("address", "User's address", addressProps, true)
    
    check(requiredSchema["type"].getStr() == "object")
    check(requiredSchema["properties"]["address"]["type"].getStr() == "object")
    check(requiredSchema["properties"]["address"]["description"].getStr() == "User's address")
    check(requiredSchema["properties"]["address"]["properties"]["street"]["type"].getStr() == "string")
    check(requiredSchema["properties"]["address"]["properties"]["city"]["type"].getStr() == "string")
    check(requiredSchema.hasKey("required"))
    check(requiredSchema["required"][0].getStr() == "address")
    
    # Create schema with optional param
    let optionalSchema = createBasicSchemaForObjectParam("address", "User's address", addressProps, false)
    
    check(optionalSchema["type"].getStr() == "object")
    check(optionalSchema["properties"]["address"]["type"].getStr() == "object")
    check(not optionalSchema.hasKey("required"))
  
  test "createBasicSchemaForArrayParam":
    # Create schema for string array with required param
    let requiredSchema = createBasicSchemaForArrayParam("tags", "User's tags", "string", true)
    
    check(requiredSchema["type"].getStr() == "object")
    check(requiredSchema["properties"]["tags"]["type"].getStr() == "array")
    check(requiredSchema["properties"]["tags"]["description"].getStr() == "User's tags")
    check(requiredSchema["properties"]["tags"]["items"]["type"].getStr() == "string")
    check(requiredSchema.hasKey("required"))
    check(requiredSchema["required"][0].getStr() == "tags")
    
    # Create schema with optional param
    let optionalSchema = createBasicSchemaForArrayParam("tags", "User's tags", "number", false)
    
    check(optionalSchema["type"].getStr() == "object")
    check(optionalSchema["properties"]["tags"]["type"].getStr() == "array")
    check(optionalSchema["properties"]["tags"]["items"]["type"].getStr() == "number")
    check(not optionalSchema.hasKey("required"))

suite "Tool Result Tests":
  test "Tool success creation":
    let success = newToolSuccess("Operation completed")
    
    check(success["isError"].getBool() == false)
    check(success["content"].len == 1)
    check(success["content"][0]["type"].getStr() == "text")
    check(success["content"][0]["text"].getStr() == "Operation completed")
    
    # Create with simple string to ensure that path is covered
    let success2 = newToolSuccess("Another success message")
    check(success2["isError"].getBool() == false)
    check(success2["content"][0]["text"].getStr() == "Another success message")
  
  test "Tool error creation":
    let error = newToolError("Operation failed")
    
    check(error["isError"].getBool() == true)
    check(error["content"].len == 1)
    check(error["content"][0]["type"].getStr() == "text")
    check(error["content"][0]["text"].getStr() == "Operation failed")
  
  test "Complex tool result creation":
    let complex = newToolSuccess(@[
      %*{"type": "text", "text": "Operation completed"},
      %*{"type": "text", "text": "Additional information"}
    ])
    
    check(complex["isError"].getBool() == false)
    check(complex["content"].len == 2)
    check(complex["content"][0]["text"].getStr() == "Operation completed")
    check(complex["content"][1]["text"].getStr() == "Additional information")

suite "Tool Response Tests":
  test "Tool response with text content":
    # Create a text response - test it directly to increase coverage
    var response: ToolResponse
    # Direct assignment to hit internal constructors
    response.isError = false
    response.content = @[
      ToolResponseContent(
        contentType: TextContent,
        text: "Direct assignment"
      )
    ]
    check(response.content[0].text == "Direct assignment")
    
    # Now test the constructor
    response = newToolResponseWithText("Hello, world!", false)
    
    check(response.isError == false)
    check(response.content.len == 1)
    check(response.content[0].contentType == TextContent)
    check(response.content[0].text == "Hello, world!")
    
    # Create another response with different parameters to increase coverage
    let response2 = newToolResponseWithText("Another text", true)
    check(response2.isError == true)
    check(response2.content[0].text == "Another text")
    
    # More explicit testing of the content type field
    check(response.content[0].contentType == TextContent)
    # Manually construct a response for comparison
    let manualResponse = ToolResponse(
      isError: false,
      content: @[
        ToolResponseContent(
          contentType: TextContent,
          text: "Hello, world!"
        )
      ]
    )
    check(response.isError == manualResponse.isError)
    check(response.content.len == manualResponse.content.len)
    check(response.content[0].text == manualResponse.content[0].text)
    
    # Convert to JSON
    let jsonResponse = toResultJson(response)
    
    check(not jsonResponse.hasKey("isError"))  # Only added if true
    check(jsonResponse["content"].len == 1)
    check(jsonResponse["content"][0]["type"].getStr() == "text")
    check(jsonResponse["content"][0]["text"].getStr() == "Hello, world!")
    
    # Create an error response
    let errorResponse = newToolResponseWithText("Error occurred", true)
    
    check(errorResponse.isError == true)
    check(errorResponse.content.len == 1)
    
    # Convert to JSON
    let jsonErrorResponse = toResultJson(errorResponse)
    
    check(jsonErrorResponse["isError"].getBool() == true)
    check(jsonErrorResponse["content"].len == 1)
    check(jsonErrorResponse["content"][0]["text"].getStr() == "Error occurred")
  
  test "Tool response with image content":
    # Base64 encoded image data (minimal example)
    let imageData = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
    let mimeType = "image/png"
    
    # Create an image response
    let response = newToolResponseWithImage(imageData, mimeType, false)
    
    check(response.isError == false)
    check(response.content.len == 1)
    check(response.content[0].contentType == ImageContent)
    check(response.content[0].data == imageData)
    check(response.content[0].mimeType == mimeType)
    
    # Convert to JSON
    let jsonResponse = toResultJson(response)
    
    check(not jsonResponse.hasKey("isError"))
    check(jsonResponse["content"].len == 1)
    check(jsonResponse["content"][0]["type"].getStr() == "image")
    check(jsonResponse["content"][0]["data"].getStr() == imageData)
    check(jsonResponse["content"][0]["mimeType"].getStr() == mimeType)
  
  test "Adding content to tool response":
    # Create a response and add content
    var response = newToolResponseWithText("Initial text", false)
    
    # Add more text
    response.addTextContent("Additional text")
    
    check(response.content.len == 2)
    check(response.content[1].contentType == TextContent)
    check(response.content[1].text == "Additional text")
    
    # Add an image
    let imageData = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
    let mimeType = "image/png"
    
    response.addImageContent(imageData, mimeType)
    
    check(response.content.len == 3)
    check(response.content[2].contentType == ImageContent)
    check(response.content[2].data == imageData)
    check(response.content[2].mimeType == mimeType)
    
    # Convert to JSON
    let jsonResponse = toResultJson(response)
    
    check(jsonResponse["content"].len == 3)
    check(jsonResponse["content"][0]["type"].getStr() == "text")
    check(jsonResponse["content"][1]["type"].getStr() == "text")
    check(jsonResponse["content"][2]["type"].getStr() == "image")

suite "Tool Config Tests":
  test "Tool config creation and conversion to JSON":
    # Create a tool config
    let config = newToolConfig(
      "test-tool",
      "Test tool description",
      %*{
        "type": "object",
        "properties": {
          "input": {"type": "string"}
        }
      }
    )
    
    check(config.name == "test-tool")
    check(config.description == "Test tool description")
    check(config.inputSchema.hasKey("type"))
    
    # Convert to JSON info
    let jsonInfo = toInfoJson(config)
    
    check(jsonInfo["name"].getStr() == "test-tool")
    check(jsonInfo["description"].getStr() == "Test tool description")
    check(jsonInfo["inputSchema"].hasKey("type"))
    
    # Create with empty description
    let minimalConfig = newToolConfig(
      "minimal",
      "",
      %*{"type": "object"}
    )
    
    # Convert to JSON info
    let minimalJsonInfo = toInfoJson(minimalConfig)
    
    check(minimalJsonInfo["name"].getStr() == "minimal")
    check(not minimalJsonInfo.hasKey("description"))