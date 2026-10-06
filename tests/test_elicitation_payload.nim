## The payload rules of elicitation/create: what a requested schema may
## contain, what a form request looks like, and when a response matches the
## schema. These are the rules behind both ways of carrying elicitation
## (a request of the server before 2026-07-28, an input request after).
##
## Expectations name their versions or are derived from `has`, so the file
## passes whatever the build's default version is.

import std/[unittest, json, strutils]
import protocol/version
import protocol/features
import protocol/types
import protocol/elicitation
import protocol/lifecycle

const
  FormVersions = [mpv20250618, mpv20251125, mpv20260728]
  EnumVersions = [mpv20251125, mpv20260728]

func schemaOf(prop: JsonNode): JsonNode =
  %*{"type": "object", "properties": {"x": prop}}

let
  titledSingle = %*{"type": "string", "oneOf": [
    {"const": "#f00", "title": "Red"}, {"const": "#0f0", "title": "Green"}],
    "default": "#f00"}
  untitledMulti = %*{"type": "array", "minItems": 1, "maxItems": 2,
    "items": {"type": "string", "enum": ["r", "g", "b"]}, "default": ["r", "g"]}
  titledMulti = %*{"type": "array", "items": {"anyOf": [
    {"const": "#f00", "title": "Red"}, {"const": "#0f0", "title": "Green"}]},
    "default": ["#f00"]}

let contactSchema = %*{
  "type": "object",
  "properties": {
    "name": {"type": "string", "minLength": 2, "maxLength": 20},
    "email": {"type": "string", "format": "email"},
    "age": {"type": "integer", "minimum": 18, "maximum": 120},
    "score": {"type": "number", "minimum": 0},
    "subscribe": {"type": "boolean"}},
  "required": ["name", "email"]}

func mentions(problems: seq[string], text: string): bool =
  for p in problems:
    if text in p: return true

suite "elicitation: the requested schema":

  test "Given a flat object of primitive properties, when checked, then there is nothing to report":
    for v in FormVersions:
      check requestedSchemaProblems(contactSchema, v).len == 0

  test "Given a schema that is not an object type, when checked, then it is reported":
    for v in FormVersions:
      check requestedSchemaProblems(%*{"type": "string"}, v).mentions("type")
      check requestedSchemaProblems(newJNull(), v).len > 0
      check requestedSchemaProblems(%*{"type": "object"}, v).mentions("properties")

  test "Given a nested object property, when checked, then the property is named":
    for v in FormVersions:
      let nested = %*{"type": "object", "properties": {
        "address": {"type": "object", "properties": {"city": {"type": "string"}}}}}
      check requestedSchemaProblems(nested, v).mentions("address")

  test "Given an array of objects, when checked, then it is reported in every version":
    for v in FormVersions:
      let arrays = %*{"type": "object", "properties": {
        "rows": {"type": "array", "items": {"type": "object"}}}}
      check requestedSchemaProblems(arrays, v).mentions("rows")

  test "Given a property with no known type, when checked, then it is reported":
    for v in FormVersions:
      let odd = %*{"type": "object", "properties": {"x": {"type": "null"}, "y": {}}}
      let problems = requestedSchemaProblems(odd, v)
      check problems.mentions("x")
      check problems.mentions("y")

  test "Given a string format outside the four the specification lists, when checked, then it is reported":
    let bad = %*{"type": "object", "properties": {"x": {"type": "string", "format": "uuid"}}}
    for v in FormVersions:
      check requestedSchemaProblems(bad, v).mentions("format")
    for format in ["email", "uri", "date", "date-time"]:
      let good = %*{"type": "object", "properties": {"x": {"type": "string", "format": format}}}
      check requestedSchemaProblems(good, mpv20250618).len == 0

  test "Given a required name that is not a property, when checked, then it is reported":
    let bad = %*{"type": "object", "properties": {"a": {"type": "string"}}, "required": ["b"]}
    check requestedSchemaProblems(bad, mpv20250618).mentions("b")

  test "Given a plain enum with display names, when checked, then it is accepted in every version":
    let colours = %*{"type": "object", "properties": {"colour": {
      "type": "string", "enum": ["r", "g"], "enumNames": ["Red", "Green"]}}}
    for v in FormVersions:
      check requestedSchemaProblems(colours, v).len == 0

  test "Given an enum whose names do not pair with its values, when checked, then it is reported":
    let bad = %*{"type": "object", "properties": {"colour": {
      "type": "string", "enum": ["r", "g"], "enumNames": ["Red"]}}}
    check requestedSchemaProblems(bad, mpv20250618).mentions("enumNames")

  test "Given a boolean with a default in 2025-06-18, when checked, then it is accepted":
    let schema = %*{"type": "object", "properties": {"ok": {"type": "boolean", "default": true}}}
    check requestedSchemaProblems(schema, mpv20250618).len == 0

suite "elicitation: enum schemas (2025-11-25)":

  test "Given titled and untitled, single and multi-select enums, when checked in 2025-11-25 and later, then they are accepted":
    let untitledSingle = %*{"type": "string", "enum": ["a", "b"], "default": "a"}
    for v in EnumVersions:
      for prop in [untitledSingle, titledSingle, untitledMulti, titledMulti]:
        check requestedSchemaProblems(schemaOf(prop), v).len == 0

  test "Given oneOf or an array property, when checked in 2025-06-18, then it is reported":
    check requestedSchemaProblems(schemaOf(%*{"type": "string", "oneOf": [
      {"const": "a", "title": "A"}]}), mpv20250618).mentions("oneOf")
    check requestedSchemaProblems(schemaOf(untitledMulti), mpv20250618).mentions("array")

  test "Given a oneOf entry without const or title, when checked, then the property is named":
    for bad in [%*{"const": "a"}, %*{"title": "A"}, %*{"const": 1, "title": "A"}]:
      let prop = %*{"type": "string", "oneOf": [bad]}
      for v in EnumVersions:
        check requestedSchemaProblems(schemaOf(prop), v).mentions("'x'")
    check requestedSchemaProblems(schemaOf(%*{"type": "string", "oneOf": []}),
                                  mpv20251125).mentions("oneOf")

  test "Given a property with both enum and oneOf, when checked, then it is reported":
    let both = %*{"type": "string", "enum": ["a"], "oneOf": [{"const": "a", "title": "A"}]}
    check requestedSchemaProblems(schemaOf(both), mpv20251125).mentions("both")

  test "Given a multi-select whose items are neither an enum nor anyOf, when checked, then it is reported":
    for items in [%*{"type": "string"}, %*{"type": "integer"}, %*{"anyOf": []}, %*"x"]:
      let prop = %*{"type": "array", "items": items}
      check requestedSchemaProblems(schemaOf(prop), mpv20251125).mentions("items")

  test "Given minItems above maxItems, when checked, then it is reported":
    let prop = %*{"type": "array", "minItems": 3, "maxItems": 2,
                  "items": {"type": "string", "enum": ["a", "b", "c"]}}
    check requestedSchemaProblems(schemaOf(prop), mpv20251125).mentions("minItems")

  test "Given a titled single-select, when a value is checked, then only a const is accepted":
    let ask = %*{"message": "m", "requestedSchema": schemaOf(titledSingle)}
    check elicitationResultProblems(%*{"action": "accept", "content": {"x": "#0f0"}}, ask).len == 0
    check elicitationResultProblems(%*{"action": "accept", "content": {"x": "Green"}}, ask).mentions("'x'")

  test "Given a multi-select, when values are checked, then they are an array of allowed values within the counts":
    let ask = %*{"message": "m", "requestedSchema": schemaOf(untitledMulti)}
    proc accepts(value: JsonNode): seq[string] =
      elicitationResultProblems(%*{"action": "accept", "content": {"x": value}}, ask)
    check accepts(%*["r", "b"]).len == 0
    check accepts(%*"r").mentions("'x'")
    check accepts(%*["r", "z"]).mentions("'x'")
    check accepts(%*[1]).mentions("'x'")
    check accepts(%*[]).mentions("minItems")
    check accepts(%*["r", "g", "b"]).mentions("maxItems")

  test "Given a titled multi-select, when values are checked, then they are consts":
    let ask = %*{"message": "m", "requestedSchema": schemaOf(titledMulti)}
    check elicitationResultProblems(%*{"action": "accept", "content": {"x": ["#f00"]}}, ask).len == 0
    check elicitationResultProblems(%*{"action": "accept", "content": {"x": ["Red"]}},
                                    ask).mentions("'x'")

suite "elicitation: default values (2025-11-25)":

  test "Given defaults on string, number, integer and enum properties, when checked in 2025-11-25 and later, then they are accepted":
    for v in EnumVersions:
      for prop in [%*{"type": "string", "default": "hi"}, %*{"type": "number", "default": 1.5},
                   %*{"type": "integer", "default": 3, "minimum": 1},
                   %*{"type": "string", "enum": ["a"], "default": "a"},
                   %*{"type": "boolean", "default": false}]:
        check requestedSchemaProblems(schemaOf(prop), v).len == 0

  test "Given a default on a string, number or enum property, when checked in 2025-06-18, then it is reported":
    for prop in [%*{"type": "string", "default": "hi"}, %*{"type": "number", "default": 1},
                 %*{"type": "string", "enum": ["a"], "default": "a"}]:
      check requestedSchemaProblems(schemaOf(prop), mpv20250618).mentions("default")

  test "Given a default that does not fit its property, when checked, then it is reported":
    for prop in [%*{"type": "string", "default": 5}, %*{"type": "integer", "default": 1.5},
                 %*{"type": "number", "default": 5, "maximum": 3},
                 %*{"type": "string", "minLength": 3, "default": "ab"},
                 %*{"type": "string", "enum": ["a"], "default": "b"},
                 %*{"type": "boolean", "default": "no"},
                 %*{"type": "array", "items": {"type": "string", "enum": ["a"]}, "default": ["z"]}]:
      check requestedSchemaProblems(schemaOf(prop), mpv20251125).mentions("default")

suite "elicitation: a form request":

  test "Given a message and a schema, when built, then the params carry them":
    for v in FormVersions:
      let params = formElicitationParams("Who are you?", contactSchema, v)
      check params["message"].getStr() == "Who are you?"
      check params["requestedSchema"] == contactSchema

  test "Given a version with URL mode, when built, then the params name the form mode; before it they do not":
    for v in FormVersions:
      let params = formElicitationParams("m", contactSchema, v)
      if v.has(ftUrlElicitation):
        check params["mode"].getStr() == "form"
      else:
        check not params.hasKey("mode")

  test "Given a schema the rules reject, when a request is built, then McpPayloadError lists the problems":
    var raised = false
    try:
      discard formElicitationParams("m", %*{"type": "string"}, mpv20250618)
    except McpPayloadError as e:
      raised = true
      check e.problems.len > 0
    check raised

  test "Given a version before elicitation, when a request is built, then McpPayloadError says so":
    expect McpPayloadError:
      discard formElicitationParams("m", contactSchema, mpv20250326)

  test "Given params without a mode, when the mode is read, then it is the form mode":
    check elicitationModeOf(%*{"message": "m", "requestedSchema": contactSchema}) == emForm
    check elicitationModeOf(%*{"mode": "form"}) == emForm

  test "Given params with an empty message or no schema, when checked, then they are reported":
    for v in FormVersions:
      check elicitationParamsProblems(%*{"requestedSchema": contactSchema}, v).mentions("message")
      check elicitationParamsProblems(%*{"message": "m"}, v).mentions("requestedSchema")
      check elicitationParamsProblems(%*{"message": "m", "requestedSchema": contactSchema}, v).len == 0

  test "Given a mode that does not exist, when the params are checked, then it is reported":
    check elicitationParamsProblems(%*{"mode": "voice", "message": "m"}, mpv20250618).mentions("mode")

suite "elicitation: a response":

  let request = %*{"message": "m", "requestedSchema": contactSchema}

  test "Given an accept with content that matches, when parsed, then the action and content come back":
    let answer = parseElicitationResult(%*{"action": "accept", "content": {
      "name": "Mona", "email": "mona@example.com", "age": 30, "score": 1.5, "subscribe": true}}, request)
    check answer.action == eaAccept
    check answer.content["name"].getStr() == "Mona"

  test "Given decline and cancel, when parsed, then there is no content":
    for action in ["decline", "cancel"]:
      let answer = parseElicitationResult(%*{"action": action}, request)
      check $answer.action == action
      check answer.content.isNil

  test "Given an action that does not exist, when parsed, then McpPayloadError names it":
    expect McpPayloadError:
      discard parseElicitationResult(%*{"action": "maybe"}, request)
    expect McpPayloadError:
      discard parseElicitationResult(%*{}, request)

  test "Given decline with content, when checked, then the content is reported":
    check elicitationResultProblems(%*{"action": "decline", "content": {"name": "x"}},
                                    request).mentions("content")

  test "Given accept without a required property, when checked, then the property is named":
    check elicitationResultProblems(%*{"action": "accept", "content": {"name": "Mona"}},
                                    request).mentions("email")

  test "Given accept without any content for a form, when checked, then it is reported":
    check elicitationResultProblems(%*{"action": "accept"}, request).mentions("content")

  test "Given a value of the wrong type, when checked, then the property is named":
    let problems = elicitationResultProblems(%*{"action": "accept", "content": {
      "name": 5, "email": "a@b.c", "age": 30.5, "score": "x", "subscribe": "yes"}}, request)
    for name in ["name", "age", "score", "subscribe"]:
      check problems.mentions(name)

  test "Given a value outside the enum, when checked, then it is reported":
    let schema = %*{"type": "object", "properties": {"colour": {
      "type": "string", "enum": ["r", "g"]}}}
    let ask = %*{"message": "m", "requestedSchema": schema}
    check elicitationResultProblems(%*{"action": "accept", "content": {"colour": "b"}},
                                    ask).mentions("colour")
    check elicitationResultProblems(%*{"action": "accept", "content": {"colour": "g"}},
                                    ask).len == 0

  test "Given strings outside the length limits, when checked, then they are reported":
    for name in ["M", "M".repeat(21)]:
      check elicitationResultProblems(%*{"action": "accept", "content": {
        "name": name, "email": "a@b.c"}}, request).mentions("name")

  test "Given numbers outside the bounds, when checked, then they are reported":
    for age in [17, 121]:
      check elicitationResultProblems(%*{"action": "accept", "content": {
        "name": "Mona", "email": "a@b.c", "age": age}}, request).mentions("age")
    check elicitationResultProblems(%*{"action": "accept", "content": {
      "name": "Mona", "email": "a@b.c", "score": -0.5}}, request).mentions("score")
    check elicitationResultProblems(%*{"action": "accept", "content": {
      "name": "Mona", "email": "a@b.c", "age": 18, "score": 0}}, request).len == 0

  test "Given values that break the format, when checked, then they are reported":
    let schema = %*{"type": "object", "properties": {
      "mail": {"type": "string", "format": "email"},
      "site": {"type": "string", "format": "uri"},
      "day": {"type": "string", "format": "date"},
      "moment": {"type": "string", "format": "date-time"}}}
    let ask = %*{"message": "m", "requestedSchema": schema}
    let bad = elicitationResultProblems(%*{"action": "accept", "content": {
      "mail": "no-at", "site": "no scheme", "day": "2026-13-40",
      "moment": "yesterday"}}, ask)
    for name in ["mail", "site", "day", "moment"]:
      check bad.mentions(name)
    check elicitationResultProblems(%*{"action": "accept", "content": {
      "mail": "a@b.c", "site": "https://example.com/x", "day": "2026-02-28",
      "moment": "2026-10-06T12:00:00Z"}}, ask).len == 0

  test "Given a result built from an action, when rendered, then content appears only with accept":
    check elicitationResultJson(McpElicitResult(action: eaDecline)) == %*{"action": "decline"}
    check elicitationResultJson(McpElicitResult(action: eaAccept,
      content: %*{"name": "Mona"})) == %*{"action": "accept", "content": {"name": "Mona"}}

suite "elicitation: URL mode (2025-11-25)":

  let
    id = "550e8400-e29b-41d4-a716-446655440000"
    link = "https://mcp.example.com/ui/set_api_key"
    urlRequest = %*{"mode": "url", "message": "Provide your key", "elicitationId": id, "url": link}

  test "Given a message, an id and a URL, when a request is built, then the params name the url mode":
    for v in EnumVersions:
      check urlElicitationParams("Provide your key", id, link, v) == urlRequest

  test "Given a version before URL mode, when a request is built or checked, then McpPayloadError and the problem name the version":
    expect McpPayloadError:
      discard urlElicitationParams("m", id, link, mpv20250618)
    check elicitationParamsProblems(urlRequest, mpv20250618).mentions("2025-06-18")

  test "Given an empty id or a string that is not a URL, when checked, then the field is named":
    for v in EnumVersions:
      check elicitationParamsProblems(%*{"mode": "url", "message": "m", "url": link}, v).mentions("elicitationId")
      check elicitationParamsProblems(%*{"mode": "url", "message": "m", "elicitationId": "",
                                         "url": link}, v).mentions("elicitationId")
      check elicitationParamsProblems(%*{"mode": "url", "message": "m", "elicitationId": id,
                                         "url": "not a url"}, v).mentions("url")
      check elicitationParamsProblems(urlRequest, v).len == 0

  test "Given params with mode url, when the mode is read, then it is the url mode":
    check elicitationModeOf(urlRequest) == emUrl

  test "Given a URL request, when it is accepted without content, then the answer is valid":
    let answer = parseElicitationResult(%*{"action": "accept"}, urlRequest)
    check answer.action == eaAccept
    check answer.content.isNil
    check $parseElicitationResult(%*{"action": "decline"}, urlRequest).action == "decline"

  test "Given a URL request, when an accept carries content, then it is reported":
    check elicitationResultProblems(%*{"action": "accept", "content": {"k": "v"}},
                                    urlRequest).mentions("content")

  test "Given the capability forms, when read, then an empty object is the form mode alone":
    check modeSupported(McpElicitationCapability(form: true), emForm)
    check not modeSupported(McpElicitationCapability(form: true), emUrl)
    check modeSupported(McpElicitationCapability(url: true), emUrl)

  test "Given the wire forms of capabilities.elicitation, when parsed, then each declared mode is supported and an empty object is the form mode alone":
    proc modes(wire: JsonNode): tuple[form, url: bool] =
      let capability = wire.fromJson(McpElicitationCapability)
      (modeSupported(capability, emForm), modeSupported(capability, emUrl))
    check modes(%*{}) == (true, false)
    check modes(%*{"form": {}}) == (true, false)
    check modes(%*{"url": {}}) == (false, true)
    check modes(%*{"form": {}, "url": {}}) == (true, true)

  test "Given an elicitation id, when a completion is built, then the params carry it":
    check elicitationCompleteParams(id, mpv20251125) == %*{"elicitationId": id}
    expect McpPayloadError:
      discard elicitationCompleteParams("", mpv20251125)
    expect McpPayloadError:
      discard elicitationCompleteParams(id, mpv20250618)

  test "Given URL requests, when an error is built, then the data lists them under elicitations":
    let data = urlElicitationRequiredData(@[urlRequest], mpv20251125)
    check data == %*{"elicitations": [urlRequest]}
    check UrlElicitationRequiredCode == -32042

  test "Given no requests, a form request or a request of the wrong version, when an error is built, then McpPayloadError is raised":
    expect McpPayloadError:
      discard urlElicitationRequiredData(@[], mpv20251125)
    expect McpPayloadError:
      discard urlElicitationRequiredData(@[formElicitationParams("m", contactSchema, mpv20251125)], mpv20251125)
    expect McpPayloadError:
      discard urlElicitationRequiredData(@[urlRequest], mpv20250618)
    expect McpPayloadError:
      discard urlElicitationRequiredData(@[urlRequest], mpv20260728)

  test "Given error data, when checked, then each entry must be a URL request":
    check urlElicitationRequiredProblems(%*{"elicitations": [urlRequest]}, mpv20251125).len == 0
    check urlElicitationRequiredProblems(%*{}, mpv20251125).mentions("elicitations")
    check urlElicitationRequiredProblems(%*{"elicitations": [{"mode": "form"}]}, mpv20251125).len > 0
