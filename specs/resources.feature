Feature: Resources
  As an application that gives a model context
  I want a server to list and read its resources and tell me when they change
  So that the model works from current data

  Specification: server/resources in every version. Before 2026-07-28 a client
  subscribes with resources/subscribe; 2026-07-28 removed that request.

  @spec:MCP-RESOURCES-1 @feature:ftResources
  Scenario: A server lists its resources and reads one
    Given a server that declared the resources capability and has resources
    When a client sends resources/list and resources/read
    Then the list result has a resources array whose entries carry uri and name
    And the read result has a contents array whose entries carry the uri and either text or blob

  @spec:MCP-RESOURCES-2 @feature:ftResources
  Scenario: A client lists and reads resources
    Given a server with resources
    When the client lists them and reads one
    Then it receives each resource's uri, name, mimeType and size, and the text and blob entries of the content

  @spec:MCP-RESOURCES-3 @feature:ftResources
  Scenario: A server without the resources capability does not serve resources
    Given a server that did not declare the resources capability
    When a client sends resources/list or resources/read
    Then the answer is method not found

  @spec:MCP-RESOURCES-4 @feature:ftResources
  Scenario: An unknown resource before 2026-07-28 is error -32002
    Given a server whose handler finds no resource for a uri
    When a client reads that uri in a version before 2026-07-28
    Then the answer is the error -32002 with the uri in its data

  @spec:MCP-RESOURCES-5 @feature:ftResourceNotFoundInvalidParams
  Scenario: An unknown resource from 2026-07-28 is invalid params
    Given a server whose handler finds no resource for a uri
    When a client reads that uri in 2026-07-28
    Then the answer is the error -32602 with the uri in its data
    And it is an error, never a result with an empty contents array

  @spec:MCP-RESOURCES-6 @feature:ftResourceTemplates
  Scenario: A server lists resource templates
    Given a server that declared the resources capability
    When a client sends resources/templates/list
    Then the entries are in a resourceTemplates array, which is empty when the server has no templates
    And a server without the resources capability answers method not found

  @spec:MCP-RESOURCES-7 @feature:ftResourceTemplates
  Scenario: A client lists resource templates
    Given a server with resource templates
    When the client lists them
    Then it reads uriTemplate and name from the resourceTemplates array

  @spec:MCP-RESOURCES-8 @feature:ftResourceSubscribe
  Scenario: A subscriber is told when its resource is updated, and nobody else
    Given a version before 2026-07-28 and a server that declared resources.subscribe
    When a client subscribes to a uri and the server then updates that uri
    Then that client gets notifications/resources/updated with the uri
    And an update of another uri sends nothing
    And another client that did not subscribe is not told

  @spec:MCP-RESOURCES-9 @feature:ftResourceSubscribe
  Scenario: Unsubscribing, or ending the session, ends the updates
    Given a subscribed client in a version before 2026-07-28
    When the client unsubscribes, or its session ends, and the resource is then updated
    Then the client is not told

  @spec:MCP-RESOURCES-10 @feature:ftResourceSubscribe
  Scenario: A subscription needs the capability, a uri and an initialized session
    Given a version before 2026-07-28
    When a client subscribes to a server that did not declare resources.subscribe, or without a uri, or before it has initialized
    Then the answers are method not found, invalid params and invalid request in that order
    And a server's own handler may refuse a resource, in which case the client gets that error and no subscription

  @spec:MCP-RESOURCES-11 @feature:ftResourceSubscribe
  Scenario: A client subscribes and unsubscribes
    Given a server that declared resources.subscribe
    When the client subscribes to a uri and unsubscribes
    Then both requests are sent with the uri
    And the client refuses to send either when the server did not declare resources.subscribe
    And the client passes the uri of each resources/updated notification to its callback

  @spec:MCP-RESOURCES-12 @feature:ftResources
  Scenario: 2026-07-28 has no resources/subscribe
    Given a 2026-07-28 connection
    When a client sends resources/subscribe or resources/unsubscribe
    Then the answer is method not found
    And the client refuses to send either

  @spec:MCP-LISTCHANGED-1 @feature:ftResources
  Scenario: A server that declared listChanged tells each initialized session when a list changes
    Given a version before 2026-07-28 and a server that declared listChanged for tools, prompts and resources
    When its tool list, prompt list or resource list changes
    Then each initialized session is told on its own session with the notification of that list
    And a session that has not sent initialized is not told
    And a server that did not declare listChanged sends nothing
    And one session whose transport fails does not keep the others from being told

  @spec:MCP-LISTCHANGED-2 @feature:ftResources
  Scenario: A client hears list-changed notifications
    Given a connected client with a callback for each list
    When the server reports that its tools, prompts or resources changed
    Then each callback fires once, a callback that raises does not stop later notifications, and without callbacks they are ignored

  @spec:MCP-RESOURCES-13 @feature:ftResources
  Scenario: A resources or prompts method needs a handler as well as the capability
    Given a server that declared the resources and prompts capabilities and registered no handlers
    When a client sends resources/list, resources/read, prompts/list or prompts/get
    Then the answer is method not found
