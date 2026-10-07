Feature: Subscriptions (2026-07-28)
  As a client that wants to hear of changes
  I want one stream of the notifications I opted in to
  So that I need neither resources/subscribe nor a GET stream

  @spec:MCP-SUBSCRIBE-1 @feature:ftSubscriptionsListen
  Scenario: The filter and the messages follow the specification
    Given the specification's listen request, acknowledgment and closing result
    When they are parsed and built
    Then they match, malformed filters are rejected and a filter wants only what it names

  @spec:MCP-SUBSCRIBE-2 @feature:ftSubscriptionsListen
  Scenario: The server acknowledges first and only what it can deliver
    Given a listen request
    When the server accepts it
    Then the first message is the acknowledgment carrying the subscription id, with the unsupported types omitted

  @spec:MCP-SUBSCRIBE-3 @feature:ftSubscriptionsListen
  Scenario: Notifications go to the streams that asked for them
    Given open subscriptions with different filters
    When tools, prompts, resources or a resource uri change
    Then each stream gets exactly the notifications it opted in to, tagged with its own subscription id

  @spec:MCP-SUBSCRIBE-4 @feature:ftSubscriptionsListen
  Scenario: Request-scoped notifications stay with their request
    Given an open subscription and a tool call that reports progress
    When the tool reports
    Then the notification belongs to the call and not to the subscription

  @spec:MCP-SUBSCRIBE-5 @feature:ftSubscriptionsListen
  Scenario: A client ends a subscription
    Given an open subscription
    When the client cancels it, or the transport reports it abandoned
    Then the subscription is gone and the server sends no response

  @spec:MCP-SUBSCRIBE-6 @feature:ftSubscriptionsListen
  Scenario: A server ends subscriptions gracefully
    Given open subscriptions
    When the server ends them
    Then each request is answered with a complete result naming its subscription, and over stdio notifications/cancelled comes first
    And ending them again does not cancel or answer a stream twice

  @spec:MCP-SUBSCRIBE-7 @feature:ftSubscriptionsListen
  Scenario: A malformed filter is invalid params
    Given a listen request without a usable notifications filter
    When it arrives
    Then it is invalid params and no subscription is opened

  @spec:MCP-SUBSCRIBE-8 @feature:ftSubscriptionsListen
  Scenario: Earlier versions keep resources/subscribe
    Given a version before 2026-07-28
    When a client asks for subscriptions/listen or subscribes to a resource
    Then listen is method not found, the client API refuses without sending, and resources/subscribe notifications arrive untagged

  @spec:MCP-SUBSCRIBE-9 @feature:ftSubscriptionsListen
  Scenario: A client listens and receives
    Given a server that acknowledges
    When the client listens
    Then it sends the filter with the request metadata, learns what was honored and sees the notifications of its stream only

  @spec:MCP-SUBSCRIBE-10 @feature:ftSubscriptionsListen
  Scenario: A client learns how a stream ended
    Given an open subscription
    When the server answers, the server cancels, the client cancels or the transport fails
    Then the stream ends gracefully, by the server, by the client or lost, in that order

  @spec:MCP-SUBSCRIBE-11 @feature:ftSubscriptionsListen
  Scenario: A client refuses a bad start
    Given a server that rejects the request, never acknowledges or acknowledges wrongly
    When the client listens
    Then it raises McpRequestError, McpTimeoutError or McpProtocolError and holds no subscription

  @spec:MCP-SUBSCRIBE-12 @feature:ftSubscriptionsListen
  Scenario: Subscriptions work over stdio and Streamable HTTP
    Given a client and a server on a stdio-style transport or on Streamable HTTP
    When the tool list changes and the subscription is cancelled or ended by the server
    Then the client is told on the response stream and the server drops the subscription

  @spec:MCP-SUBSCRIBE-13 @feature:ftSubscriptionsListen
  Scenario: An extension takes part in the acknowledgment through a listen filter hook
    Given a server with listen filter hooks
    When a client listens
    Then each hook runs in the order added, sees what was asked, and the acknowledgment carries what they leave in the filter
