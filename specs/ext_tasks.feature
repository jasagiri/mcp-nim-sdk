Feature: Tasks extension (2026-07-28)
  As a server or client of long-running work
  I want the official Tasks extension (io.modelcontextprotocol/tasks)
  So that a tool call can become a task that is polled, fed input and cancelled

  Based on ext-tasks at 5246bc3d0253c1c4b09e682f690b7e8b97362500. An extension, not
  part of the core: only a server or client that enabled it declares it, so the
  specs below carry no @feature tag. Import it as `import ext/tasks`.

  @spec:MCP-EXT-TASKS-1
  Scenario: The task is written the way the extension's schema says
    Given a task and a CreateTaskResult
    When they are parsed and written
    Then the fields are flat, with ttlMs (null for unlimited) and pollIntervalMs, and resultType task on the handle

  @spec:MCP-EXT-TASKS-2
  Scenario: A DetailedTask carries what its status requires
    Given tasks/get results and notifications of each status
    When they are parsed
    Then input_required needs inputRequests, completed a result object, failed an error with code and message, and an unknown status is rejected

  @spec:MCP-EXT-TASKS-3
  Scenario: The extension is declared only where it was enabled and 2026-07-28 is spoken
    Given a server or client that enabled the extension, or did not
    When it declares its capabilities or enables the extension
    Then the server lists io.modelcontextprotocol/tasks in server/discover with empty settings, the client in every request, a 2025-11-25 client sees the core's capability instead, and enabling in a build or for a version that does not speak 2026-07-28 raises

  @spec:MCP-EXT-TASKS-4
  Scenario: A client that did not declare the extension never gets a task
    Given a client without the extension on the request
    When it calls a tool, uses tasks/get, tasks/update or tasks/cancel, or the tool exists only as a task
    Then it gets the plain result, or -32021 naming the extension in requiredCapabilities for the tasks methods and the task-only tool, and method not found when the server did not enable it

  @spec:MCP-EXT-TASKS-5
  Scenario: The server alone decides, request by request, whether a call becomes a task
    Given a client that declared the extension
    When it calls a tool
    Then the server's decider picks a task or the result per call, none makes no task, a request already running as a task is not made one again, and the answer is a CreateTaskResult the client can poll at once

  @spec:MCP-EXT-TASKS-6
  Scenario: tasks/get returns what the underlying request returned
    Given a task
    When it is polled before and after the work ends
    Then the result is inlined for completed (an isError tool result stays completed), the JSON-RPC error for failed, with resultType complete and no resultType inside the result

  @spec:MCP-EXT-TASKS-7
  Scenario: A task that does not exist is -32602, and tasks are bounded
    Given an unknown, malformed or expired task id, or an owner at its limit
    When tasks/get, tasks/update or tasks/cancel is sent or another task is asked for
    Then the answer is -32602 for the id and an error with no task made for the limit

  @spec:MCP-EXT-TASKS-8
  Scenario: tasks/cancel is a cooperative acknowledgement
    Given a working or finished task
    When tasks/cancel is sent
    Then the answer is empty, the work is told to stop, a finished task keeps its status and a cancelled one stays cancelled

  @spec:MCP-EXT-TASKS-9
  Scenario: The extension reserves tasks/ and takes tasks/get and tasks/cancel from the core's removed methods
    Given tasks/result, tasks/list and the three methods the extension defines
    When a client asks, or another extension registers one
    Then tasks/result and tasks/list are method not found and no other extension may register a reserved method

  @spec:MCP-EXT-TASKS-10
  Scenario: Over Streamable HTTP the task methods carry Mcp-Name
    Given tasks/get, tasks/update and tasks/cancel
    When the headers are built and checked
    Then Mcp-Name is the taskId and a missing or different value is a header mismatch

  @spec:MCP-EXT-TASKS-11
  Scenario: Input during a task goes through inputRequests and tasks/update
    Given a task that needs input from the client
    When it is polled and the client answers
    Then it is input_required with the outstanding requests, tasks/update acknowledges and the task goes on, responses to keys not outstanding are ignored, malformed ones are -32602, keys are never reused, and the client answers each key once from a callback or its handlers

  @spec:MCP-EXT-TASKS-12
  Scenario: Input gathered before the task is resolved with multi round-trip requests first
    Given a tool that needs input before it starts
    When the first call is answered input_required and the retry carries the responses
    Then the task is created only on the retry

  @spec:MCP-EXT-TASKS-13
  Scenario: A task belongs to its owner
    Given tasks of two owners
    When one asks for the other's task
    Then it is unknown to the asker
    And without an owner function the owner is the authorized principal of the request
    And without authorization either, all clients are one owner and only the task id separates them

  @spec:MCP-EXT-TASKS-14
  Scenario: Task status can be pushed over subscriptions/listen
    Given a client that listed task ids
    When a task changes status
    Then the acknowledgement lists the ids agreed to (its own), a client without the extension gets -32021, and each change is sent as notifications/tasks with the whole task

  @spec:MCP-EXT-TASKS-15
  Scenario: The client gets either answer and follows the task
    Given a client that declared the extension
    When it calls a tool
    Then it gets the result or the task, polls at the interval the task suggests, and callToolAwaitingTask returns the final result, raises the task's error, or reports cancellation; a task from a server that did not declare the extension is a protocol error

  @spec:MCP-EXT-TASKS-16
  Scenario: One server serves the core's Tasks and the extension's from one store
    Given a server with both and clients of 2025-11-25 and 2026-07-28
    When each calls a tool
    Then the old client gets the core's nested task, the new one the flat task, neither sees the other's, the store's ttl cap and clock apply to both, and a 2025-11-25 client's extensions capability is ignored
