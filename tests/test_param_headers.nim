## x-mcp-header (2026-07-28): which tool declarations are valid, how call
## arguments become Mcp-Param-* headers, and how a server checks them.
##
## Expectations follow server/tools "x-mcp-header" and
## basic/transports/streamable-http "Custom Headers from Tool Parameters".

import std/[unittest, json, options, strutils]
import protocol/types
import protocol/modern
import protocol/param_headers

proc schema(properties: JsonNode): JsonNode =
  %*{"type": "object", "properties": properties}

proc headersOf(declarations: ParamDeclarations, arguments: JsonNode): seq[(string, string)] =
  check declarations.invalid.isNone
  check paramHeadersFor(declarations.bindings, arguments, result).isNone

proc mismatchOf(declarations: ParamDeclarations, arguments: JsonNode,
                received: openArray[(string, string)]): Option[JsonRpcError] =
  checkParamHeaders(declarations.bindings, arguments, received)

let sqlSchema = schema(%*{
  "region": {"type": "string", "x-mcp-header": "Region"},
  "query": {"type": "string"}})

suite "x-mcp-header: valid declarations":

  test "Given the specification's execute_sql schema, when declarations are read, then Region is bound to region":
    let declared = declaredParamHeaders(sqlSchema)
    check declared.invalid.isNone
    check declared.bindings == @[ParamBinding(name: "Region", path: @["region"], kind: pkString)]
    check declared.bindings[0].headerName == "Mcp-Param-Region"

  test "Given a schema without annotations, when declarations are read, then it is valid and binds nothing":
    let declared = declaredParamHeaders(schema(%*{"a": {"type": "string"}}))
    check declared.invalid.isNone
    check declared.bindings.len == 0

  test "Given no schema at all, when declarations are read, then it is valid and binds nothing":
    check declaredParamHeaders(nil).invalid.isNone
    check declaredParamHeaders(%"not a schema").invalid.isNone

  test "Given an annotated property in a nested object, when declarations are read, then the path follows the properties keys":
    let declared = declaredParamHeaders(schema(%*{
      "target": {"type": "object", "properties": {
        "zone": {"type": "integer", "x-mcp-header": "Zone"}}}}))
    check declared.invalid.isNone
    check declared.bindings == @[ParamBinding(name: "Zone", path: @["target", "zone"], kind: pkInteger)]

  test "Given integer, string and boolean properties, when declarations are read, then all three are accepted":
    let declared = declaredParamHeaders(schema(%*{
      "a": {"type": "integer", "x-mcp-header": "A"},
      "b": {"type": "string", "x-mcp-header": "B"},
      "c": {"type": "boolean", "x-mcp-header": "C"}}))
    check declared.invalid.isNone
    check declared.bindings.len == 3

  test "Given a property named x-mcp-header, when declarations are read, then it is a property and not an annotation":
    let declared = declaredParamHeaders(schema(%*{
      "x-mcp-header": {"type": "string"}}))
    check declared.invalid.isNone
    check declared.bindings.len == 0

suite "x-mcp-header: invalid declarations":

  proc invalid(properties: JsonNode): bool =
    declaredParamHeaders(schema(properties)).invalid.isSome

  test "Given an empty name, when declarations are read, then the tool is invalid":
    check invalid(%*{"a": {"type": "string", "x-mcp-header": ""}})

  test "Given a name that is not a token, when declarations are read, then the tool is invalid":
    check invalid(%*{"a": {"type": "string", "x-mcp-header": "Bad Name"}})
    check invalid(%*{"a": {"type": "string", "x-mcp-header": "Bad:Name"}})
    check invalid(%*{"a": {"type": "string", "x-mcp-header": "Bad\r\nName"}})
    check invalid(%*{"a": {"type": "string", "x-mcp-header": "Naïve"}})

  test "Given a name that is not a string, when declarations are read, then the tool is invalid":
    check invalid(%*{"a": {"type": "string", "x-mcp-header": 7}})
    check invalid(%*{"a": {"type": "string", "x-mcp-header": ["A"]}})

  test "Given two names that differ only in case, when declarations are read, then the tool is invalid":
    check invalid(%*{
      "a": {"type": "string", "x-mcp-header": "Region"},
      "b": {"type": "string", "x-mcp-header": "REGION"}})

  test "Given a number property, when declarations are read, then the tool is invalid":
    check invalid(%*{"a": {"type": "number", "x-mcp-header": "A"}})

  test "Given an object or array property, when declarations are read, then the tool is invalid":
    check invalid(%*{"a": {"type": "object", "x-mcp-header": "A"}})
    check invalid(%*{"a": {"type": "array", "x-mcp-header": "A"}})

  test "Given an annotated property with no type, when declarations are read, then the tool is invalid":
    check invalid(%*{"a": {"x-mcp-header": "A"}})

  test "Given an annotation on the schema root, when declarations are read, then the tool is invalid":
    check declaredParamHeaders(%*{"type": "object", "x-mcp-header": "A"}).invalid.isSome

  test "Given an annotation under items, when declarations are read, then the tool is invalid":
    check invalid(%*{"list": {"type": "array", "items": {"type": "string", "x-mcp-header": "A"}}})

  test "Given an annotation under composition, conditional or $ref keywords, when declarations are read, then the tool is invalid":
    for keyword in ["oneOf", "anyOf", "allOf"]:
      check invalid(%*{"a": {keyword: [{"type": "string", "x-mcp-header": "A"}]}})
    check invalid(%*{"a": {"not": {"type": "string", "x-mcp-header": "A"}}})
    check invalid(%*{"a": {"if": {"type": "string", "x-mcp-header": "A"}}})
    check invalid(%*{"a": {"then": {"type": "string", "x-mcp-header": "A"}}})
    check invalid(%*{"a": {"else": {"type": "string", "x-mcp-header": "A"}}})
    let viaRef = %*{"type": "object", "properties": {"a": {"$ref": "#/$defs/p"}},
                    "$defs": {"p": {"type": "string", "x-mcp-header": "A"}}}
    check declaredParamHeaders(viaRef).invalid.isSome

  test "Given keywords that hold schemas but no annotation, when declarations are read, then the tool stays valid":
    let declared = declaredParamHeaders(schema(%*{
      "list": {"type": "array", "items": {"type": "string"}},
      "free": {"type": "object", "additionalProperties": {"type": "integer"}},
      "pick": {"anyOf": [{"type": "string"}, {"type": "integer"}]},
      "inner": {"type": "object", "properties": {"x-mcp-header": {"type": "string"}}},
      "id": {"type": "string", "x-mcp-header": "Id"}}))
    check declared.invalid.isNone
    check declared.bindings.len == 1

  test "Given an invalid declaration, when declarations are read, then the reason names where it was found":
    let nested = declaredParamHeaders(schema(%*{
      "target": {"type": "object", "properties": {
        "zone": {"type": "number", "x-mcp-header": "Zone"}}}}))
    check "'target.zone'" in nested.invalid.get
    let root = declaredParamHeaders(%*{"type": "object", "x-mcp-header": "A"})
    check "the schema root" in root.invalid.get
    let stray = declaredParamHeaders(%*{"type": "object", "not": {"x-mcp-header": "A"}})
    check "the schema root" in stray.invalid.get
    let strayBelow = declaredParamHeaders(schema(%*{
      "a": {"type": "string", "not": {"x-mcp-header": "A"}}}))
    check "'a'" in strayBelow.invalid.get

  test "Given an empty name, when declarations are read, then the reason says the name must not be empty":
    let declared = declaredParamHeaders(schema(%*{"a": {"type": "string", "x-mcp-header": ""}}))
    check "non-empty" in declared.invalid.get

  test "Given an invalid declaration, when declarations are read, then no bindings are offered":
    let declared = declaredParamHeaders(schema(%*{
      "a": {"type": "string", "x-mcp-header": "A"},
      "b": {"type": "number", "x-mcp-header": "B"}}))
    check declared.invalid.isSome
    check declared.bindings.len == 0

suite "x-mcp-header: client headers":

  test "Given the specification's call, when headers are built, then Mcp-Param-Region carries the region":
    let declared = declaredParamHeaders(sqlSchema)
    check headersOf(declared, %*{"region": "us-west1", "query": "SELECT * FROM users"}) ==
      @[("Mcp-Param-Region", "us-west1")]

  test "Given an argument that is absent or null, when headers are built, then the header is omitted":
    let declared = declaredParamHeaders(sqlSchema)
    check headersOf(declared, %*{"query": "q"}).len == 0
    check headersOf(declared, %*{"region": nil, "query": "q"}).len == 0
    check headersOf(declared, newJObject()).len == 0

  test "Given an argument at a nested path, when headers are built, then the value at the exact path is used":
    let declared = declaredParamHeaders(schema(%*{
      "target": {"type": "object", "properties": {
        "zone": {"type": "integer", "x-mcp-header": "Zone"}}}}))
    check headersOf(declared, %*{"target": {"zone": 42}}) == @[("Mcp-Param-Zone", "42")]
    check headersOf(declared, %*{"zone": 42}).len == 0

  test "Given integer and boolean arguments, when headers are built, then they are decimal and lowercase":
    let declared = declaredParamHeaders(schema(%*{
      "n": {"type": "integer", "x-mcp-header": "N"},
      "ok": {"type": "boolean", "x-mcp-header": "Ok"},
      "off": {"type": "boolean", "x-mcp-header": "Off"}}))
    check headersOf(declared, %*{"n": -7, "ok": true, "off": false}) ==
      @[("Mcp-Param-N", "-7"), ("Mcp-Param-Ok", "true"), ("Mcp-Param-Off", "false")]

  test "Given values that are not plain header values, when headers are built, then they use the Base64 sentinel as in the specification's table":
    let declared = declaredParamHeaders(schema(%*{
      "greeting": {"type": "string", "x-mcp-header": "Greeting"},
      "text": {"type": "string", "x-mcp-header": "Text"},
      "val": {"type": "string", "x-mcp-header": "Val"}}))
    check headersOf(declared, %*{"greeting": "Hello, 世界"}) ==
      @[("Mcp-Param-Greeting", "=?base64?SGVsbG8sIOS4lueVjA==?=")]
    check headersOf(declared, %*{"text": " padded "}) ==
      @[("Mcp-Param-Text", "=?base64?IHBhZGRlZCA=?=")]
    check headersOf(declared, %*{"text": "line1\nline2"}) ==
      @[("Mcp-Param-Text", "=?base64?bGluZTEKbGluZTI=?=")]
    check headersOf(declared, %*{"val": "=?base64?literal?="}) ==
      @[("Mcp-Param-Val", "=?base64?PT9iYXNlNjQ/bGl0ZXJhbD89?=")]

  test "Given an integer beyond the safe range, when headers are built, then the value is refused and no header is added":
    let declared = declaredParamHeaders(schema(%*{
      "n": {"type": "integer", "x-mcp-header": "N"}}))
    var headers: seq[(string, string)] = @[("Existing", "1")]
    check paramHeadersFor(declared.bindings, %*{"n": 9_007_199_254_740_992'i64}, headers).isSome
    check paramHeadersFor(declared.bindings, %*{"n": -9_007_199_254_740_992'i64}, headers).isSome
    check headers == @[("Existing", "1")]
    check paramHeadersFor(declared.bindings, %*{"n": 9_007_199_254_740_991'i64}, headers).isNone
    check paramHeadersFor(declared.bindings, %*{"n": -9_007_199_254_740_991'i64}, headers).isNone
    check headers == @[("Existing", "1"), ("Mcp-Param-N", "9007199254740991"),
                       ("Mcp-Param-N", "-9007199254740991")]

  test "Given an argument of the wrong type, when headers are built, then the value is refused":
    let declared = declaredParamHeaders(schema(%*{
      "n": {"type": "integer", "x-mcp-header": "N"},
      "s": {"type": "string", "x-mcp-header": "S"},
      "b": {"type": "boolean", "x-mcp-header": "B"}}))
    var headers: seq[(string, string)] = @[]
    check paramHeadersFor(declared.bindings, %*{"n": "7"}, headers).isSome
    check paramHeadersFor(declared.bindings, %*{"n": 1.5}, headers).isSome
    check paramHeadersFor(declared.bindings, %*{"s": 7}, headers).isSome
    check paramHeadersFor(declared.bindings, %*{"b": "true"}, headers).isSome
    check headers.len == 0

suite "x-mcp-header: server validation":

  test "Given a header that equals the body, when checked, then the request is accepted":
    let declared = declaredParamHeaders(sqlSchema)
    check mismatchOf(declared, %*{"region": "us-west1"}, [("Mcp-Param-Region", "us-west1")]).isNone

  test "Given a header name in another case, when checked, then it is still the same header":
    let declared = declaredParamHeaders(sqlSchema)
    check mismatchOf(declared, %*{"region": "us-west1"}, [("mcp-param-REGION", "us-west1")]).isNone

  test "Given a header that differs from the body, when checked, then the error is HeaderMismatch":
    let declared = declaredParamHeaders(sqlSchema)
    let error = mismatchOf(declared, %*{"region": "us-west1"}, [("Mcp-Param-Region", "eu-1")])
    check error.isSome
    check error.get.code == ErrHeaderMismatch

  test "Given a body value and no header, when checked, then the request is rejected":
    let declared = declaredParamHeaders(sqlSchema)
    check mismatchOf(declared, %*{"region": "us-west1"}, @[]).get.code == ErrHeaderMismatch

  test "Given a header and no body value, when checked, then the request is rejected":
    let declared = declaredParamHeaders(sqlSchema)
    check mismatchOf(declared, newJObject(), [("Mcp-Param-Region", "us-west1")]).get.code == ErrHeaderMismatch

  test "Given a null body value and no header, when checked, then no header is expected":
    let declared = declaredParamHeaders(sqlSchema)
    check mismatchOf(declared, %*{"region": nil}, @[]).isNone

  test "Given a Base64 header, when checked, then it is decoded before the comparison":
    let declared = declaredParamHeaders(sqlSchema)
    check mismatchOf(declared, %*{"region": "Hello, 世界"},
      [("Mcp-Param-Region", "=?base64?SGVsbG8sIOS4lueVjA==?=")]).isNone

  test "Given a header with characters a plain value may not have, when checked, then it is rejected":
    let declared = declaredParamHeaders(sqlSchema)
    check mismatchOf(declared, %*{"region": "a b"}, [("Mcp-Param-Region", "a\x01b")]).isSome
    check mismatchOf(declared, %*{"region": "世界"}, [("Mcp-Param-Region", "世界")]).isSome
    check mismatchOf(declared, %*{"region": "x"}, [("Mcp-Param-Region", "=?base64?***?=")]).isSome

  test "Given the same header twice, when checked, then the request is rejected":
    let declared = declaredParamHeaders(sqlSchema)
    check mismatchOf(declared, %*{"region": "x"},
      [("Mcp-Param-Region", "x"), ("Mcp-Param-Region", "x")]).isSome

  test "Given an integer header, when checked, then it is compared numerically with the body":
    let declared = declaredParamHeaders(schema(%*{"n": {"type": "integer", "x-mcp-header": "N"}}))
    check mismatchOf(declared, %*{"n": 42}, [("Mcp-Param-N", "42")]).isNone
    check mismatchOf(declared, %*{"n": 42}, [("Mcp-Param-N", "42.0")]).isNone
    check mismatchOf(declared, %*{"n": 42}, [("Mcp-Param-N", "43")]).isSome
    check mismatchOf(declared, %*{"n": 42}, [("Mcp-Param-N", "forty-two")]).isSome

  test "Given a body number written with a fraction part, when checked, then it agrees with the same integer in the header":
    let declared = declaredParamHeaders(schema(%*{"n": {"type": "integer", "x-mcp-header": "N"}}))
    check mismatchOf(declared, parseJson("""{"n": 42.0}"""), [("Mcp-Param-N", "42")]).isNone
    check mismatchOf(declared, parseJson("""{"n": 42.0}"""), [("Mcp-Param-N", "43")]).isSome

  test "Given an object or array argument, when checked, then no header value agrees with it":
    let declared = declaredParamHeaders(sqlSchema)
    for body in [%*{"region": ["x"]}, %*{"region": {"x": 1}}]:
      check mismatchOf(declared, body, [("Mcp-Param-Region", "x")]).get.code == ErrHeaderMismatch

  test "Given a boolean header, when checked, then only true and false in lowercase agree":
    let declared = declaredParamHeaders(schema(%*{"b": {"type": "boolean", "x-mcp-header": "B"}}))
    check mismatchOf(declared, %*{"b": true}, [("Mcp-Param-B", "true")]).isNone
    check mismatchOf(declared, %*{"b": false}, [("Mcp-Param-B", "false")]).isNone
    check mismatchOf(declared, %*{"b": true}, [("Mcp-Param-B", "True")]).isSome
    check mismatchOf(declared, %*{"b": true}, [("Mcp-Param-B", "false")]).isSome

  test "Given headers the tool did not declare, when checked, then they are left alone":
    let declared = declaredParamHeaders(sqlSchema)
    check mismatchOf(declared, %*{"region": "x"},
      [("Mcp-Param-Region", "x"), ("Mcp-Param-Other", "anything")]).isNone

  test "Given a long mismatching value, when the error is built, then the message quotes only a prefix":
    let declared = declaredParamHeaders(sqlSchema)
    let error = mismatchOf(declared, %*{"region": "x"}, [("Mcp-Param-Region", repeat("y", 5000))])
    check error.get.message.len < 300
