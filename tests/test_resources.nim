# Model Context Protocol (MCP) Server SDK for Nim
#
# Tests for the MCP resources implementation.

import unittest, json, asyncdispatch, options
import ../src/mcp/resources
import ../src/mcp/types

suite "Resource Registry Tests":
  setup:
    let registry = newResourceRegistry()
  
  test "Resource registration and retrieval":
    # Register a resource
    registry.registerResource(
      "file:///example.txt",
      "Example Text File",
      some("A simple text file example"),
      some("text/plain"),
      proc(): JsonNode =
        return %*{
          "contents": [
            {
              "uri": "file:///example.txt",
              "mimeType": "text/plain",
              "text": "This is the content of the example text file."
            }
          ]
        }
    )
    
    # Get resource list
    let resources = registry.getResources()
    
    check(resources.len == 1)
    check(resources[0]["uri"].getStr() == "file:///example.txt")
    check(resources[0]["name"].getStr() == "Example Text File")
    check(resources[0]["description"].getStr() == "A simple text file example")
    check(resources[0]["mimeType"].getStr() == "text/plain")
    
    # Get resource content
    let content = registry.getResource("file:///example.txt")
    
    check(content.isSome)
    check(content.get()["contents"].len == 1)
    check(content.get()["contents"][0]["uri"].getStr() == "file:///example.txt")
    check(content.get()["contents"][0]["mimeType"].getStr() == "text/plain")
    check(content.get()["contents"][0]["text"].getStr() == "This is the content of the example text file.")
  
  test "Multiple resource registration":
    # Register resources
    registry.registerResource(
      "file:///doc1.txt",
      "Document 1",
      some("First document"),
      some("text/plain"),
      proc(): JsonNode =
        return %*{
          "contents": [
            {
              "uri": "file:///doc1.txt",
              "mimeType": "text/plain",
              "text": "Content of document 1"
            }
          ]
        }
    )
    
    registry.registerResource(
      "file:///doc2.txt",
      "Document 2",
      some("Second document"),
      some("text/plain"),
      proc(): JsonNode =
        return %*{
          "contents": [
            {
              "uri": "file:///doc2.txt",
              "mimeType": "text/plain",
              "text": "Content of document 2"
            }
          ]
        }
    )
    
    # Get resource list
    let resources = registry.getResources()
    
    check(resources.len == 2)
    
    # Get specific resource contents
    let content1 = registry.getResource("file:///doc1.txt")
    let content2 = registry.getResource("file:///doc2.txt")
    
    check(content1.isSome)
    check(content1.get()["contents"][0]["text"].getStr() == "Content of document 1")
    
    check(content2.isSome)
    check(content2.get()["contents"][0]["text"].getStr() == "Content of document 2")
  
  test "Binary resource registration":
    # Register a binary resource
    registry.registerResource(
      "file:///example.bin",
      "Example Binary File",
      some("A binary file example"),
      some("application/octet-stream"),
      proc(): JsonNode =
        return %*{
          "contents": [
            {
              "uri": "file:///example.bin",
              "mimeType": "application/octet-stream",
              "blob": "SGVsbG8sIHdvcmxkIQ==" # Base64 encoded "Hello, world!"
            }
          ]
        }
    )
    
    # Get resource list
    let resources = registry.getResources()
    
    check(resources.len == 1)
    check(resources[0]["uri"].getStr() == "file:///example.bin")
    check(resources[0]["mimeType"].getStr() == "application/octet-stream")
    
    # Get resource content
    let content = registry.getResource("file:///example.bin")
    
    check(content.isSome)
    check(content.get()["contents"].len == 1)
    check(content.get()["contents"][0]["uri"].getStr() == "file:///example.bin")
    check(content.get()["contents"][0]["mimeType"].getStr() == "application/octet-stream")
    check(content.get()["contents"][0]["blob"].getStr() == "SGVsbG8sIHdvcmxkIQ==")
  
  test "Unknown resource retrieval":
    let content = registry.getResource("file:///unknown.txt")
    check(content.isNone)

suite "Resource URI Tests":
  test "Resource URI validation":
    check(validateResourceUri("file:///path/to/file.txt") == true)
    check(validateResourceUri("custom://resource/path") == true)
    check(validateResourceUri("http://example.com/resource") == true)
    check(validateResourceUri("data:text/plain,content") == true)
    check(validateResourceUri("://invalid") == false)
    check(validateResourceUri("invalid") == false)
    check(validateResourceUri("protocol://") == false)
  
  test "Resource URI parsing":
    let uri1 = parseResourceUri("file:///path/to/file.txt")
    check(uri1.protocol == "file")
    check(uri1.path == "/path/to/file.txt")
    
    let uri2 = parseResourceUri("custom://resource/path")
    check(uri2.protocol == "custom")
    check(uri2.path == "resource/path")
    
    let uri3 = parseResourceUri("http://example.com/resource")
    check(uri3.protocol == "http")
    check(uri3.path == "example.com/resource")

suite "Resource Template Tests":
  setup:
    let registry = newResourceRegistry()
  
  test "Resource template registration and retrieval":
    # Register a resource template
    registry.registerResourceTemplate(
      "file:///docs/{name}.txt",
      "Document File",
      some("A text document"),
      some("text/plain")
    )
    
    # Get resource templates
    let templates = registry.getResourceTemplates()
    
    check(templates.len == 1)
    check(templates[0]["uriTemplate"].getStr() == "file:///docs/{name}.txt")
    check(templates[0]["name"].getStr() == "Document File")
    check(templates[0]["description"].getStr() == "A text document")
    check(templates[0]["mimeType"].getStr() == "text/plain")
