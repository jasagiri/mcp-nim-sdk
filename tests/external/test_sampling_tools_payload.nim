## The payload rules of sampling with tools (2025-11-25): what a request
## with `tools` and `toolChoice` may hold, how tool uses and tool results
## must pair up in the messages, and what a result that stops for a tool
## looks like. Like the elicitation rules these know nothing of transport.

import std/[unittest, json, options, strutils]
import protocol/version
import protocol/features
import protocol/types
import protocol/sampling_tools

const WithTools = [mpv20251125, mpv20260728]

func mentions(problems: seq[string], text: string): bool =
  for p in problems:
    if text in p: return true

let
  weather = %*{"name": "get_weather", "description": "Weather of a city",
               "inputSchema": {"type": "object", "properties": {"city": {"type": "string"}},
                               "required": ["city"]}}
  question = %*{"role": "user", "content": {"type": "text", "text": "Paris and London?"}}
  twoUses = %*{"role": "assistant", "content": [
    {"type": "tool_use", "id": "a", "name": "get_weather", "input": {"city": "Paris"}},
    {"type": "tool_use", "id": "b", "name": "get_weather", "input": {"city": "London"}}]}
  twoResults = %*{"role": "user", "content": [
    {"type": "tool_result", "toolUseId": "a", "content": [{"type": "text", "text": "18C"}]},
    {"type": "tool_result", "toolUseId": "b", "content": [{"type": "text", "text": "15C"}]}]}

func request(messages: seq[JsonNode], extra: JsonNode = nil): JsonNode =
  result = %*{"messages": messages, "maxTokens": 100}
  if not extra.isNil:
    for key, value in extra.pairs: result[key] = value

suite "sampling messages: content types by version":

  test "Given an audio block in a message, when the request is checked, then only versions with audio content accept it":
    let audio = %*{"role": "user", "content": {"type": "audio", "data": "AAAA", "mimeType": "audio/wav"}}
    for v in [mpv20241105, mpv20250326, mpv20250618, mpv20251125, mpv20260728]:
      let problems = createMessageParamsProblems(request(@[audio]), v)
      if v.has(ftAudioContent):
        check problems.len == 0
      else:
        check problems.mentions("audio")

  test "Given an image block in a message, when the request is checked, then every version accepts it":
    let image = %*{"role": "user", "content": {"type": "image", "data": "AAAA", "mimeType": "image/png"}}
    for v in [mpv20241105, mpv20250326, mpv20250618, mpv20251125, mpv20260728]:
      check createMessageParamsProblems(request(@[image]), v).len == 0

suite "sampling with tools: what the request is allowed to hold":

  test "Given tools and a tool choice, when the request is checked in 2025-11-25 and later, then there is nothing to report":
    for v in WithTools:
      for mode in ["auto", "required", "none"]:
        check createMessageParamsProblems(
          request(@[question], %*{"tools": [weather], "toolChoice": {"mode": mode}}),
          v).len == 0
      check createMessageParamsProblems(request(@[question], %*{"tools": [weather]}), v).len == 0

  test "Given a request that uses tools, when asked whether it does, then tools or toolChoice make it so":
    check usesTools(request(@[question], %*{"tools": [weather]}))
    check usesTools(request(@[question], %*{"toolChoice": {"mode": "none"}}))
    check not usesTools(request(@[question]))

  test "Given tools or a tool choice, when checked in 2025-06-18, then the field is reported":
    check createMessageParamsProblems(request(@[question], %*{"tools": [weather]}),
                                      mpv20250618).mentions("tools")
    check createMessageParamsProblems(request(@[question], %*{"toolChoice": {"mode": "auto"}}),
                                      mpv20250618).mentions("toolChoice")

  test "Given a client without sampling.tools, when the request uses tools, then the reason is that capability":
    let needs = request(@[question], %*{"tools": [weather]})
    check samplingToolsUnavailable(needs, mpv20251125, McpSamplingCapability()).isSome
    check "sampling.tools" in samplingToolsUnavailable(needs, mpv20251125, McpSamplingCapability()).get
    check samplingToolsUnavailable(needs, mpv20251125, McpSamplingCapability(tools: true)).isNone
    check samplingToolsUnavailable(request(@[question]), mpv20251125, McpSamplingCapability()).isNone

  test "Given a version without sampling tools, when the request uses them, then the reason names the version even for a client that declared the capability":
    let needs = request(@[question], %*{"tools": [weather]})
    let reason = samplingToolsUnavailable(needs, mpv20250618, McpSamplingCapability(tools: true))
    check reason.isSome
    check "2025-06-18" in reason.get

  test "Given a tool without a name or an input schema, or twice the same name, when checked, then it is reported":
    for bad in [%*{"inputSchema": {"type": "object"}}, %*{"name": "x"},
                %*{"name": "x", "inputSchema": {"type": "string"}}]:
      check createMessageParamsProblems(request(@[question], %*{"tools": [bad]}),
                                        mpv20251125).mentions("tools[0]")
    check createMessageParamsProblems(request(@[question], %*{"tools": [weather, weather]}),
                                      mpv20251125).mentions("get_weather")
    check createMessageParamsProblems(request(@[question], %*{"tools": "x"}),
                                      mpv20251125).mentions("tools")

  test "Given a tool choice mode that does not exist, when checked, then it is reported":
    check createMessageParamsProblems(
      request(@[question], %*{"tools": [weather], "toolChoice": {"mode": "always"}}),
      mpv20251125).mentions("mode")

  test "Given a request without maxTokens or messages, when checked, then they are reported":
    check createMessageParamsProblems(%*{"messages": [question]}, mpv20251125).mentions("maxTokens")
    check createMessageParamsProblems(%*{"maxTokens": 5}, mpv20251125).mentions("messages")

suite "sampling with tools: tool uses and tool results in the messages":

  test "Given tool uses answered by a message of exactly their results, when checked, then there is nothing to report":
    for v in WithTools:
      check createMessageParamsProblems(request(@[question, twoUses, twoResults]), v).len == 0

  test "Given a single tool result as an object, when checked, then it is accepted":
    let one = %*{"role": "assistant", "content": {"type": "tool_use", "id": "a", "name": "t", "input": {}}}
    let answer = %*{"role": "user", "content": {"type": "tool_result", "toolUseId": "a",
                                                "content": [{"type": "text", "text": "ok"}]}}
    check createMessageParamsProblems(request(@[question, one, answer]), mpv20251125).len == 0

  test "Given a tool result mixed with text, when checked, then it is reported":
    let mixed = %*{"role": "user", "content": [
      {"type": "text", "text": "Here are the results:"},
      {"type": "tool_result", "toolUseId": "a", "content": []}]}
    let one = %*{"role": "assistant", "content": {"type": "tool_use", "id": "a", "name": "t", "input": {}}}
    check createMessageParamsProblems(request(@[question, one, mixed]),
                                      mpv20251125).mentions("only tool results")

  test "Given tool uses with a missing result, when checked, then the id is named":
    let partial = %*{"role": "user", "content": [
      {"type": "tool_result", "toolUseId": "a", "content": []}]}
    check createMessageParamsProblems(request(@[question, twoUses, partial]),
                                      mpv20251125).mentions("'b'")

  test "Given a result for an id that was never used, when checked, then it is reported":
    let stray = %*{"role": "user", "content": [
      {"type": "tool_result", "toolUseId": "a", "content": []},
      {"type": "tool_result", "toolUseId": "b", "content": []},
      {"type": "tool_result", "toolUseId": "zzz", "content": []}]}
    check createMessageParamsProblems(request(@[question, twoUses, stray]),
                                      mpv20251125).mentions("'zzz'")
    check createMessageParamsProblems(request(@[stray]), mpv20251125).mentions("'zzz'")

  test "Given tool uses followed by another message that is not their results, when checked, then it is reported":
    check createMessageParamsProblems(request(@[question, twoUses, question]),
                                      mpv20251125).mentions("messages[2]")

  test "Given tool uses that nothing answers at the end, when checked, then it is reported":
    check createMessageParamsProblems(request(@[question, twoUses]),
                                      mpv20251125).mentions("messages[1]")

  test "Given a tool use by the user or a tool result by the assistant, when checked, then it is reported":
    let userUse = %*{"role": "user", "content": {"type": "tool_use", "id": "a", "name": "t", "input": {}}}
    check createMessageParamsProblems(request(@[userUse]), mpv20251125).mentions("assistant")
    let assistantResult = %*{"role": "assistant", "content": {"type": "tool_result", "toolUseId": "a", "content": []}}
    check createMessageParamsProblems(request(@[assistantResult]), mpv20251125).mentions("user")

  test "Given two tool uses with the same id, when checked, then it is reported":
    let dup = %*{"role": "assistant", "content": [
      {"type": "tool_use", "id": "a", "name": "t", "input": {}},
      {"type": "tool_use", "id": "a", "name": "t", "input": {}}]}
    check createMessageParamsProblems(request(@[question, dup]), mpv20251125).mentions("'a'")

  test "Given tool blocks or array content, when checked in 2025-06-18, then they are reported":
    check createMessageParamsProblems(request(@[question,
      %*{"role": "assistant", "content": {"type": "tool_use", "id": "a", "name": "t", "input": {}}}]),
      mpv20250618).mentions("tool_use")
    check createMessageParamsProblems(request(@[question, twoUses, twoResults]),
                                      mpv20250618).mentions("array")
    check createMessageParamsProblems(
      request(@[%*{"role": "user", "content": [{"type": "text", "text": "a"}]}]),
      mpv20250618).mentions("array")

  test "Given a block that is malformed, when checked, then the message is named":
    for bad in [%*{"type": "text"}, %*{"type": "image", "data": "x"}, %*{"type": "hologram"},
                %*{"type": "tool_use", "id": "a", "name": "t"}, %*"x"]:
      check createMessageParamsProblems(
        request(@[%*{"role": "assistant", "content": bad}]), mpv20251125).mentions("messages[0]")
    check createMessageParamsProblems(
      request(@[%*{"role": "robot", "content": {"type": "text", "text": "x"}}]),
      mpv20251125).mentions("role")
    check createMessageParamsProblems(
      request(@[%*{"role": "user", "content": []}]), mpv20251125).mentions("content")

suite "sampling with tools: the result":

  let toolsRequest = request(@[question], %*{"tools": [weather]})
  let toolUse = %*{"type": "tool_use", "id": "a", "name": "get_weather", "input": {"city": "Paris"}}

  test "Given a result that stops for tool use with tool_use blocks, when checked, then it is valid":
    for v in WithTools:
      check createMessageResultProblems(%*{"role": "assistant", "content": [toolUse],
        "model": "m", "stopReason": "toolUse"}, toolsRequest, v).len == 0
      check createMessageResultProblems(%*{"role": "assistant", "content": toolUse,
        "model": "m", "stopReason": "toolUse"}, toolsRequest, v).len == 0

  test "Given two tool_use blocks with the same id, when checked, then it is reported":
    check createMessageResultProblems(%*{"role": "assistant", "content": [toolUse, toolUse.copy()],
      "model": "m", "stopReason": "toolUse"}, toolsRequest, mpv20251125).mentions("'a'")

  test "Given stopReason toolUse without a tool_use block, when checked, then it is reported":
    check createMessageResultProblems(%*{"role": "assistant",
      "content": {"type": "text", "text": "x"}, "model": "m", "stopReason": "toolUse"},
      toolsRequest, mpv20251125).mentions("toolUse")

  test "Given tool_use blocks that the request did not allow, when checked, then it is reported":
    let plain = request(@[question])
    check createMessageResultProblems(%*{"role": "assistant", "content": [toolUse],
      "model": "m", "stopReason": "toolUse"}, plain, mpv20251125).mentions("tools")
    let forbidden = request(@[question], %*{"tools": [weather], "toolChoice": {"mode": "none"}})
    check createMessageResultProblems(%*{"role": "assistant", "content": [toolUse],
      "model": "m", "stopReason": "toolUse"}, forbidden, mpv20251125).mentions("none")

  test "Given tool choice required and no tool used yet, when the result completes without a tool_use, then it is reported":
    let required = request(@[question], %*{"tools": [weather], "toolChoice": {"mode": "required"}})
    check createMessageResultProblems(%*{"role": "assistant",
      "content": {"type": "text", "text": "x"}, "model": "m", "stopReason": "endTurn"},
      required, mpv20251125).mentions("required")
    let later = request(@[question, twoUses, twoResults],
                        %*{"tools": [weather], "toolChoice": {"mode": "required"}})
    check createMessageResultProblems(%*{"role": "assistant",
      "content": {"type": "text", "text": "x"}, "model": "m", "stopReason": "endTurn"},
      later, mpv20251125).len == 0

  test "Given a result without role, content or model, when checked, then the field is reported":
    let plain = request(@[question])
    check createMessageResultProblems(%*{"content": {"type": "text", "text": "x"}, "model": "m"},
                                      plain, mpv20251125).mentions("role")
    check createMessageResultProblems(%*{"role": "assistant", "model": "m"},
                                      plain, mpv20251125).mentions("content")
    check createMessageResultProblems(%*{"role": "assistant", "content": {"type": "text", "text": "x"}},
                                      plain, mpv20251125).mentions("model")

  test "Given tool uses, when they are read from a result, then they come back as blocks in order":
    let blocks = toolUsesOf(%*{"role": "assistant", "content": [
      {"type": "text", "text": "thinking"}, toolUse], "model": "m", "stopReason": "toolUse"})
    check blocks == @[toolUse]
    check toolUsesOf(%*{"role": "assistant", "content": toolUse, "model": "m"}) == @[toolUse]
    check toolUsesOf(%*{"role": "assistant", "content": {"type": "text", "text": "x"},
                        "model": "m"}).len == 0

  test "Given values, when tool blocks are built, then they have the wire shape":
    check toolUseBlock("a", "get_weather", %*{"city": "Paris"}) == toolUse
    check toolResultBlock("a", @[%*{"type": "text", "text": "18C"}]) ==
      %*{"type": "tool_result", "toolUseId": "a", "content": [{"type": "text", "text": "18C"}]}
    check toolResultBlock("a", @[], isError = true, structuredContent = %*{"t": 1}) ==
      %*{"type": "tool_result", "toolUseId": "a", "content": [], "isError": true,
         "structuredContent": {"t": 1}}

# One fault per message sequence: each test below breaks exactly one rule, so
# the number of problems says whether that rule was checked at all.

let
  oneUse = %*{"role": "assistant", "content": {"type": "tool_use", "id": "a", "name": "t", "input": {}}}

func answeredBy(resultBlock: JsonNode): JsonNode =
  %*{"role": "user", "content": [resultBlock]}

func textResultOf(blockOfContent: JsonNode): JsonNode =
  %*{"role": "assistant", "content": blockOfContent, "model": "m", "stopReason": "endTurn"}

suite "sampling with tools: absent and non-object values":

  test "Given no params, no answer or an answer without content, when asked for tool uses, then there are none":
    check not usesTools(nil)
    check toolUsesOf(nil).len == 0
    check toolUsesOf(%*"x").len == 0
    check toolUsesOf(%*{"role": "assistant", "model": "m"}).len == 0

  test "Given content blocks without a usable type, when asked for tool uses, then they are not tool uses":
    let untyped = %*{"role": "assistant", "model": "m",
                     "content": [{"text": "x"}, {"type": 5}, "x", toolUseBlock("a", "t", %*{})]}
    check toolUsesOf(untyped) == @[toolUseBlock("a", "t", %*{})]
    check createMessageResultProblems(untyped, request(@[question], %*{"tools": [weather]}),
                                      mpv20251125).len == 3

  test "Given params that are not an object, when checked, then that is the only problem":
    for bad in [newJNull(), %*[1]]:
      for v in WithTools:
        let problems = createMessageParamsProblems(bad, v)
        check problems.len == 1
        check problems.mentions("params")
    check createMessageParamsProblems(nil, mpv20251125).mentions("params")

  test "Given a result that is not an object, when checked, then that is the only problem":
    for bad in [%*[1], %*"x"]:
      let problems = createMessageResultProblems(bad, request(@[question]), mpv20251125)
      check problems.len == 1
      check problems.mentions("object")
    check createMessageResultProblems(nil, request(@[question]), mpv20251125).mentions("object")

  test "Given a message that is not an object or has no content, when checked, then that message is the only problem":
    for v in WithTools:
      let notObject = createMessageParamsProblems(request(@[%*"x"]), v)
      check notObject.len == 1
      check notObject.mentions("messages[0]")
      let noContent = createMessageParamsProblems(request(@[%*{"role": "user"}]), v)
      check noContent.len == 1
      check noContent.mentions("content")

  test "Given an array of content whose entry is not a content block, when checked, then that entry is the only problem":
    for entry in [%*"x", %*{"text": "x"}, %*{"type": 5}]:
      let problems = createMessageParamsProblems(
        request(@[%*{"role": "user", "content": [entry]}]), mpv20251125)
      check problems.len == 1
      check problems.mentions("content[0]")
    let loose = createMessageParamsProblems(
      request(@[%*{"role": "user", "content": {"text": "x"}}]), mpv20251125)
    check loose.len == 1
    check loose.mentions("content[0]")

  test "Given a tool choice that is not an object, when checked, then it is the only problem":
    for v in WithTools:
      let problems = createMessageParamsProblems(
        request(@[question], %*{"tools": [weather], "toolChoice": "required"}), v)
      check problems.len == 1
      check problems.mentions("toolChoice")

suite "sampling with tools: the fields of a tool_use and a tool_result":

  let toolsRequest = request(@[question], %*{"tools": [weather]})

  test "Given a tool_use without an id, with an empty id, without a name or without an input object, when a result holds it, then that field is the only problem":
    for (field, block0) in [
        ("id", %*{"type": "tool_use", "name": "t", "input": {}}),
        ("id", %*{"type": "tool_use", "id": "", "name": "t", "input": {}}),
        ("name", %*{"type": "tool_use", "id": "a", "input": {}}),
        ("input", %*{"type": "tool_use", "id": "a", "name": "t"}),
        ("input", %*{"type": "tool_use", "id": "a", "name": "t", "input": "x"})]:
      let problems = createMessageResultProblems(
        %*{"role": "assistant", "content": [block0], "model": "m", "stopReason": "toolUse"},
        toolsRequest, mpv20251125)
      check problems.len == 1
      check problems.mentions(field)

  test "Given a tool_result without a toolUseId, when checked, then the field is reported":
    let problems = createMessageParamsProblems(request(@[question, oneUse,
      answeredBy(%*{"type": "tool_result", "content": []})]), mpv20251125)
    check problems.mentions("toolUseId")

  test "Given a tool_result whose content is missing, not an array or not content blocks, when checked, then that is the only problem":
    for broken in [%*{"type": "tool_result", "toolUseId": "a"},
                   %*{"type": "tool_result", "toolUseId": "a", "content": "x"},
                   %*{"type": "tool_result", "toolUseId": "a", "content": [1]},
                   %*{"type": "tool_result", "toolUseId": "a", "content": [{"text": "x"}]}]:
      let problems = createMessageParamsProblems(
        request(@[question, oneUse, answeredBy(broken)]), mpv20251125)
      check problems.len == 1
      check problems.mentions("content")

  test "Given a tool_result with structuredContent or isError of the wrong kind, when checked, then that field is the only problem":
    let wrongStructured = createMessageParamsProblems(request(@[question, oneUse, answeredBy(
      %*{"type": "tool_result", "toolUseId": "a", "content": [], "structuredContent": "x"})]),
      mpv20251125)
    check wrongStructured.len == 1
    check wrongStructured.mentions("structuredContent")
    let wrongError = createMessageParamsProblems(request(@[question, oneUse, answeredBy(
      %*{"type": "tool_result", "toolUseId": "a", "content": [], "isError": "yes"})]),
      mpv20251125)
    check wrongError.len == 1
    check wrongError.mentions("isError")

  test "Given a tool_result with structuredContent as an object and isError as a boolean, when checked, then there is nothing to report":
    for flag in [true, false]:
      check createMessageParamsProblems(request(@[question, oneUse, answeredBy(
        %*{"type": "tool_result", "toolUseId": "a", "content": [{"type": "text", "text": "ok"}],
           "structuredContent": {"t": 1}, "isError": flag})]), mpv20251125).len == 0

suite "sampling with tools: pairing reports each violation once":

  test "Given tool uses followed by a message that is not their results, when checked, then that message is the only problem":
    let problems = createMessageParamsProblems(request(@[question, twoUses, question]), mpv20251125)
    check problems.len == 1
    check problems.mentions("messages[2]")

  test "Given two tool results for one id, when checked, then the repeat is the only problem":
    let repeated = %*{"role": "user", "content": [
      {"type": "tool_result", "toolUseId": "a", "content": []},
      {"type": "tool_result", "toolUseId": "a", "content": []},
      {"type": "tool_result", "toolUseId": "b", "content": []}]}
    let problems = createMessageParamsProblems(request(@[question, twoUses, repeated]), mpv20251125)
    check problems.len == 1
    check problems.mentions("'a'")

suite "sampling with tools: the content of a result":

  test "Given array content or an unknown content type in a result, when checked, then the version and the block decide":
    for v in [mpv20241105, mpv20250326, mpv20250618, mpv20251125, mpv20260728]:
      let plain = request(@[question])
      check createMessageResultProblems(textResultOf(%*{"type": "text", "text": "x"}), plain, v).len == 0
      let asArray = createMessageResultProblems(textResultOf(%*[{"type": "text", "text": "x"}]), plain, v)
      if v.has(ftSamplingTools):
        check asArray.len == 0
      else:
        check asArray.len == 1
        check asArray.mentions("array")
      let unknown = createMessageResultProblems(textResultOf(%*{"type": "hologram"}), plain, v)
      check unknown.len == 1
      check unknown.mentions("content[0]")

  test "Given a result that completes without a tool use, when the tool choice is not required, then it is valid":
    let text = textResultOf(%*{"type": "text", "text": "x"})
    for extra in [%*{}, %*{"tools": [weather]}, %*{"tools": [weather], "toolChoice": {"mode": "auto"}},
                  %*{"tools": [weather], "toolChoice": {"mode": "none"}}]:
      check createMessageResultProblems(text, request(@[question], extra), mpv20251125).len == 0
    check createMessageResultProblems(text, nil, mpv20251125).len == 0

  test "Given tool choice required and a message without content, when a result completes without a tool use, then the absence of a tool use is reported":
    let required = request(@[%*{"role": "user"}], %*{"tools": [weather], "toolChoice": {"mode": "required"}})
    check createMessageResultProblems(textResultOf(%*{"type": "text", "text": "x"}),
                                      required, mpv20251125).mentions("required")
