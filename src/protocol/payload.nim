## What a payload check reports. The checks of the protocol modules that
## carry no transport (elicitation, sampling with tools) return a list of
## problems; a caller that cannot go on raises `McpPayloadError` with it.

type
  McpPayloadError* = object of ValueError
    ## A payload breaks a rule of the specification. `msg` joins `problems`.
    problems*: seq[string]

func newPayloadError*(context: string, problems: seq[string]): ref McpPayloadError =
  ## `problems` must not be empty: an error without a reason helps nobody.
  doAssert problems.len > 0, "a payload error needs at least one problem"
  result = (ref McpPayloadError)(problems: problems)
  result.msg = context & ": " & problems[0]
  for i in 1 ..< problems.len:
    result.msg.add "; " & problems[i]

func raiseIfAny*(context: string, problems: seq[string]) {.raises: [McpPayloadError].} =
  if problems.len > 0:
    raise newPayloadError(context, problems)
