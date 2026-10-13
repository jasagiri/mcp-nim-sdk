Feature: Multi round-trip requests (2026-07-28)
  As the author of a server whose tool needs the user's input
  I want to ask for it in the middle of a request and finish when the client retries
  So that no state is kept between the attempts

  @spec:MCP-MRTR-1 @feature:ftMultiRoundTripRequests
  Scenario: The input_required types follow the specification
    Given the specification's InputRequiredResult examples
    When they are parsed, built, compared with capabilities and turned into a retry
    Then they match, malformed results are rejected and the retry echoes the state exactly

  @spec:MCP-MRTR-2 @feature:ftMultiRoundTripRequests
  Scenario: A handler asks for input and finishes on the retry
    Given a tool that needs an elicitation
    When it is called and then retried with the answers and the state
    Then the first answer is input_required with the request and state and the retry completes

  @spec:MCP-MRTR-3 @feature:ftMultiRoundTripRequests
  Scenario: Missing answers are asked for again
    Given a retry that answers only some of the requests
    When the handler runs again
    Then only the missing requests are asked again

  @spec:MCP-MRTR-4 @feature:ftMultiRoundTripRequests
  Scenario: A server may ask only for a retry with a state
    Given a handler that raises input required with a state alone
    When it is called
    Then the answer carries the state and no requests

  @spec:MCP-MRTR-5 @feature:ftMultiRoundTripRequests
  Scenario: A server does not ask for what the client did not declare
    Given a client that did not declare the capability a request needs
    When the handler asks for it
    Then the answer is the missing-capability error naming the capability

  @spec:MCP-MRTR-6 @feature:ftMultiRoundTripRequests
  Scenario: Only tools/call, prompts/get and resources/read may need input
    Given handlers of those requests and of another request
    When they ask for input, or ask for nothing
    Then the three answer input_required and the others, and an empty ask, are internal errors

  @spec:MCP-MRTR-7 @feature:ftMultiRoundTripRequests
  Scenario: Malformed input fields are invalid params
    Given inputResponses or requestState of the wrong type
    When the request arrives
    Then it is invalid params

  @spec:MCP-MRTR-8 @feature:ftMultiRoundTripRequests
  Scenario: Earlier versions have no multi round-trips
    Given a version before 2026-07-28
    When a handler asks for input
    Then it is an internal error and the input fields are ignored

  @spec:MCP-MRTR-9 @feature:ftMultiRoundTripRequests
  Scenario: Input requests carry the request's trace context
    Given a request with trace context
    When the server asks for input
    Then each input request carries the context

  @spec:MCP-MRTR-10 @feature:ftMultiRoundTripRequests
  Scenario: The request state is sealed
    Given a state sealed for a method, parameters and principal
    When it is opened for the same or for something else, tampered with or expired
    Then only the same request gets the payload and the peer is never told why

  @spec:MCP-MRTR-11 @feature:ftMultiRoundTripRequests
  Scenario: A client answers input requests and retries
    Given an input_required answer and handlers for the requests
    When the client collects the answers
    Then it retries with a new id, the answers and the state echoed exactly, and sends no state the server did not send

  @spec:MCP-MRTR-12 @feature:ftMultiRoundTripRequests
  Scenario: A client bounds the retries
    Given a server that keeps asking
    When the limit of rounds is reached
    Then the client raises McpInputRoundsError

  @spec:MCP-MRTR-13 @feature:ftMultiRoundTripRequests
  Scenario: A client refuses what it cannot answer
    Given requests the client did not declare, has no handler for, or whose handler fails
    When the server asks
    Then the client raises without retrying

  @spec:MCP-MRTR-14 @feature:ftMultiRoundTripRequests
  Scenario: A client rejects input_required where it is not allowed or malformed
    Given input_required for tools/list or a malformed result
    When it arrives
    Then the client raises McpProtocolError

  @spec:MCP-MRTR-15 @feature:ftMultiRoundTripRequests
  Scenario: Time spent answering is not request time
    Given a slow answer to the input requests and a request timeout
    When the client collects the answers
    Then the timeout counts each attempt, not the answering

  @spec:MCP-MRTR-16 @feature:ftMultiRoundTripRequests
  Scenario: A server does not send an input request that breaks the rules of its method
    Given a handler that asks for an elicitation without a requestedSchema, or a sampling without messages
    When the request is answered
    Then the answer is an internal error and nothing is asked of the client

  @spec:MCP-MRTR-17 @feature:ftMultiRoundTripRequests
  Scenario: An input request needs the part of the capability it uses
    Given a client that declared elicitation without the url mode, or sampling without tools
    When a handler asks for a URL elicitation, or a sampling with tools
    Then the answer is the missing-capability error naming elicitation.url, or sampling.tools
    And a client that receives such a request raises McpProtocolError without calling its handler or retrying

  @spec:MCP-MRTR-18 @feature:ftMultiRoundTripRequests
  Scenario: A client answers an elicitation input request through its elicitation handler
    Given a server that answers tools/call with a form elicitation as an input request
    When the client's handler accepts with content that fits the schema
    Then the retry carries the ElicitResult under the request's key
    And when the handler answers outside the schema, the request is abandoned and nothing is retried

  @spec:MCP-MRTR-19 @feature:ftMultiRoundTripRequests
  Scenario: A server asks only for elicitation, sampling or roots
    Given a handler that asks for a request that is none of the three
    When it is called
    Then the answer is an internal error and nothing is asked

  @spec:MCP-MRTR-20 @feature:ftMultiRoundTripRequests
  Scenario: A server does not wait for the client to retry
    Given a request answered with input_required
    When the client never retries, retries the same request again, or retries on a server that never saw the first
    Then the first request is already answered, the server asks again each time, and the retry completes on any server

  @spec:MCP-MRTR-21 @feature:ftMultiRoundTripRequests
  Scenario: Input answers and state belong to the request that asked
    Given one request waiting for its input answers and another request sent meanwhile
    When both run
    Then the other request carries no inputResponses and no requestState, nor does one sent afterwards

  @spec:MCP-MRTR-22 @feature:ftMultiRoundTripRequests
  Scenario: Answers the server did not ask for are ignored
    Given a retry that carries answers under keys the server did not ask for
    When the server runs the request
    Then they are ignored, and what is still missing is asked for again

  @spec:MCP-MRTR-23 @feature:ftMultiRoundTripRequests
  Scenario: The keys of the input requests of one answer are unique
    Given a handler that asks for two different requests under one key
    When it is called
    Then the answer is an error and no request is lost silently
