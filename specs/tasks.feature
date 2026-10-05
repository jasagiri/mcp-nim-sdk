Feature: Tasks
  As a client or a server that asks for something that takes long
  I want to hand the request over as a task and come back for the result
  So that polling, waiting and cancelling do not need an open request

  Tasks are in the core of 2025-11-25 only (basic/utilities/tasks). Before it
  there are none, and in 2026-07-28 they are an official extension, so a
  server of those versions answers tasks/* as unknown methods and ignores a
  `task` parameter.

  @spec:MCP-TASKS-1 @feature:ftTasks
  Scenario: A server declares what it can do with tasks
    Given a server with tasks enabled
    When a client handshakes in 2025-11-25
    Then the capability names tasks.list, tasks.cancel and tasks.requests.tools.call, each only when supported
    And a client that declares tasks is read the same way

  @spec:MCP-TASKS-2
  Scenario: Versions without tasks in the core have none
    Given a server with tasks enabled
    When a client of a version before 2025-11-25, or of 2026-07-28, uses it
    Then no tasks capability is declared, tasks/get, tasks/result, tasks/list and tasks/cancel are unknown methods, and a task parameter on a call is ignored

  @spec:MCP-TASKS-3 @feature:ftTasks
  Scenario: A tool says whether a call may be a task
    Given tools whose execution.taskSupport is forbidden, optional, required or absent
    When a call carries a task, or does not
    Then a task is refused with method not found for forbidden and absent, and a call without one is refused for required
    And a server that did not declare tasks.requests.tools.call runs the call normally

  @spec:MCP-TASKS-4 @feature:ftTasks
  Scenario: A task-augmented call is answered with a working task at once
    Given a tool that allows a task
    When a call carries a task with a ttl
    Then the answer is a CreateTaskResult in status working with the granted ttl, createdAt, lastUpdatedAt and pollInterval, and holds no tool result
    And the receiver may override the ttl, and may add a model-immediate-response to _meta

  @spec:MCP-TASKS-5 @feature:ftTasks
  Scenario: A task id is made by the receiver and cannot be guessed
    Given a receiver
    When it creates many tasks
    Then every id is a distinct string of at least 128 random bits

  @spec:MCP-TASKS-6 @feature:ftTasks
  Scenario: A task follows the status transitions of the specification
    Given a task
    When its status changes
    Then working may move to input_required, completed, failed and cancelled, input_required may also move back to working, and a terminal status never changes
    And lastUpdatedAt moves with every change

  @spec:MCP-TASKS-7 @feature:ftTasks
  Scenario: A task is polled with tasks/get
    Given a task
    When the requestor asks for it with tasks/get
    Then it gets the task, without related-task metadata, whatever metadata the request carried
    And an unknown or missing taskId is invalid params

  @spec:MCP-TASKS-8 @feature:ftTasks
  Scenario: tasks/result waits for the end and returns exactly what the request returned
    Given a working task
    When the requestor asks for its result
    Then the answer comes when the task is terminal, is the result with the related-task metadata, or the same JSON-RPC error
    And a tool result with isError makes the task failed while the result stays a result
    And a cancelled task has no result and the answer is an error

  @spec:MCP-TASKS-9 @feature:ftTasks
  Scenario: Tasks are listed page by page
    Given more tasks than fit a page
    When the requestor lists them with tasks/list and follows nextCursor
    Then every task appears once and the last page has no cursor
    And a cursor nobody issued is invalid params, and a receiver without tasks.list does not know the method

  @spec:MCP-TASKS-10 @feature:ftTasks
  Scenario: A task is cancelled with tasks/cancel
    Given a working task
    When the requestor cancels it
    Then the task is cancelled before the answer, the work behind it is told to stop and the task stays cancelled when that work ends anyway
    And a task that is terminal cannot be cancelled: invalid params
    And a receiver without tasks.cancel does not know the method

  @spec:MCP-TASKS-11 @feature:ftTasks
  Scenario: A receiver may announce a status change
    Given a task of a session
    When its status changes
    Then that session, and no other, is sent notifications/tasks/status with the whole task

  @spec:MCP-TASKS-12 @feature:ftTasks
  Scenario: A task is deleted when its ttl has elapsed
    Given a task with a ttl
    When the ttl has elapsed, whatever the status
    Then it is gone for tasks/get, tasks/result and tasks/list, and the work still running behind it is told to stop
    And a task with unlimited ttl stays

  @spec:MCP-TASKS-13 @feature:ftTasks
  Scenario: A task belongs to the session that made it
    Given tasks of two sessions
    When one session asks for, waits for or cancels a task of the other
    Then it is told the task is not found, and lists only its own tasks

  @spec:MCP-TASKS-14 @feature:ftTasks
  Scenario: A task that needs input from the requestor says so
    Given a task whose tool asks the client for something
    When the request goes out
    Then it names the task in _meta, goes with the tasks/result request that waits on the task if there is one, and the task is input_required until the client answers, then working

  @spec:MCP-TASKS-15 @feature:ftTasks
  Scenario: A receiver can limit the tasks a requestor has
    Given a limit of active tasks per owner
    When it is reached
    Then a new task is refused with an internal error until one ends

  @spec:MCP-TASKS-16 @feature:ftTasks
  Scenario: A client calls a tool as a task
    Given a server that declares tasks.requests.tools.call
    When the client calls a tool that allows a task as a task, reads, lists, cancels and waits for it
    Then the requests are the ones of the specification, polling follows the suggested interval, and an input_required task is waited for with tasks/result
    And nothing is sent when the server, the tool or the negotiated version does not allow a task

  @spec:MCP-TASKS-17 @feature:ftTasks
  Scenario: A client receives a task-augmented sampling request
    Given a client that enabled tasks and has a sampling handler
    When the server sends sampling/createMessage with a task
    Then the client answers with a working task at once, and serves tasks/get, tasks/result, tasks/list and tasks/cancel for it
    And a request without a task is answered directly

  @spec:MCP-TASKS-18 @feature:ftTasks
  Scenario: A server asks a client for sampling as a task
    Given a client that declared tasks.requests.sampling.createMessage
    When the server asks for sampling as a task
    Then it creates the task, polls it and fetches the result, and sends nothing when the client did not declare the capability or the version has no tasks

  @spec:MCP-TASKS-19 @feature:ftTasks
  Scenario: The SDK's own client and server agree on tasks
    Given the SDK's server and client connected in 2025-11-25
    When the client calls tools as tasks, cancels one, and the server asks the client for sampling in a task and through a tool
    Then both ends agree on the wire
