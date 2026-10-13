## What a server sends in a sampling request is untrusted: a field of the
## wrong type is the server's defect, not a 0.0 the user never asked for.

import std/[json, options, unittest]
import client/sampling
import client/client except McpRequestError

suite "security sweep: what a server sends in a sampling request":
  let base = %*{"messages": [{"role": "user", "content": {"type": "text", "text": "hi"}}],
                "maxTokens": 10}

  proc with(key: string, value: JsonNode): JsonNode =
    result = base.copy()
    result[key] = value

  test "Given a temperature that is a string, when parsed, then it is a protocol error and not 0.0":
    expect McpProtocolError:
      discard parseSamplingRequest(with("temperature", %"hot"))

  test "Given a priority that is a string, when parsed, then it is a protocol error and not 0.0":
    expect McpProtocolError:
      discard parseSamplingRequest(with("modelPreferences", %*{"costPriority": "high"}))

  test "Given numbers and nulls, when parsed, then they are read as sent, a null as absent":
    let parsed = parseSamplingRequest(with("temperature", %0.7))
    check parsed.temperature == some(0.7)
    check parseSamplingRequest(with("temperature", newJNull())).temperature.isNone
    check parseSamplingRequest(with("modelPreferences", %*{"speedPriority": 1})
      ).modelPreferences.get.speedPriority == some(1.0)
