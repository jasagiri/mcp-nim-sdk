## The types of `completion/complete`, shared by the server and the client:
## what is being completed, and the suggestions.

import std/options

type
  McpCompletionRefKind* = enum
    mcrPrompt = "ref/prompt"
    mcrResourceTemplate = "ref/resource"

  McpCompletionRef* = object
    ## What is being completed: a prompt's argument or a resource
    ## template's variable.
    case kind*: McpCompletionRefKind
    of mcrPrompt:
      promptName*: string
    of mcrResourceTemplate:
      uriTemplate*: string  ## A resource URI or URI template.

  McpCompletion* = object
    values*: seq[string]
      ## Most relevant first.
    total*: Option[int]
    hasMore*: Option[bool]
      ## none when the server did not say.

func promptRef*(name: string): McpCompletionRef {.raises: [].} =
  McpCompletionRef(kind: mcrPrompt, promptName: name)

func resourceTemplateRef*(uriTemplate: string): McpCompletionRef {.raises: [].} =
  McpCompletionRef(kind: mcrResourceTemplate, uriTemplate: uriTemplate)
