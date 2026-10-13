## The procedures a server builds its tool definitions and results with,
## as a program that imports `mcp` and nothing else of the SDK reaches them.

import std/[unittest, json]
import mcp

suite "tool definitions and results built through the entry":

  test "Given a name, a description and a schema only, when a tool is defined, then it has no title, icons, annotations or outputSchema":
    let tool = createToolInfo("add", "Adds two integers", createInputSchema(
      %*{"a": createNumberProperty(), "b": createNumberProperty("the second")}, @["a", "b"]))
    check tool == %*{
      "name": "add", "description": "Adds two integers",
      "inputSchema": {"type": "object",
                      "properties": {"a": {"type": "number"},
                                     "b": {"type": "number", "description": "the second"}},
                      "required": ["a", "b"]}}

  test "Given a result built without isError, when it is read, then it is not an error":
    let answer = createToolResult(@[createTextToolContent("3")])
    check answer["content"] == %*[{"type": "text", "text": "3"}]
    check not answer["isError"].getBool()

  test "Given schemas built without a description or a required list, when they are read, then they carry neither":
    check createInputSchema(%*{}) == %*{"type": "object", "properties": {}}
    check createStringProperty() == %*{"type": "string"}
    check createBooleanProperty() == %*{"type": "boolean"}
    check createArrayProperty(createStringProperty()) == %*{"type": "array", "items": {"type": "string"}}
    check createObjectProperty(%*{}) == %*{"type": "object", "properties": {}}
    check createEnumProperty(@["a", "b"]) == %*{"type": "string", "enum": ["a", "b"]}
