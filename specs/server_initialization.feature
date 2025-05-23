Feature: MCP Server Initialization
  As a MCP Server implementer
  I want to properly initialize an MCP server
  So that clients can connect and interact with it

  Background:
    Given the MCP protocol version is "2024-11-26"

  Scenario: Server initialization with default capabilities
    Given I have created a new MCP server with metadata
      | name         | version |
      | "test-server" | "1.0.0" |
    When I initialize the server
    Then the server should set up the default handlers
    And be ready to handle initialize requests

  Scenario: Server initialization with resource capabilities
    Given I have created a new MCP server with metadata
      | name         | version |
      | "test-server" | "1.0.0" |
    And I have added resource capabilities
      | subscribe | listChanged |
      | true      | true        |
    When I initialize the server
    Then the server should set up resource request handlers
    And be able to handle resource requests including:
      | method                      |
      | "resources/list"            |
      | "resources/templates/list"  |
      | "resources/read"            |
      | "resources/subscribe"       |
      | "resources/unsubscribe"     |

  Scenario: Server initialization with tool capabilities
    Given I have created a new MCP server with metadata
      | name         | version |
      | "test-server" | "1.0.0" |
    And I have added tool capabilities
      | listChanged |
      | true        |
    When I initialize the server
    Then the server should set up tool request handlers
    And be able to handle tool requests including:
      | method       |
      | "tools/list" |
      | "tools/call" |

  Scenario: Server initialization with prompt capabilities
    Given I have created a new MCP server with metadata
      | name         | version |
      | "test-server" | "1.0.0" |
    And I have added prompt capabilities
      | listChanged |
      | true        |
    When I initialize the server
    Then the server should set up prompt request handlers
    And be able to handle prompt requests including:
      | method        |
      | "prompts/list" |
      | "prompts/get"  |

  Scenario: Server initialization with sampling capabilities
    Given I have created a new MCP server with metadata
      | name         | version |
      | "test-server" | "1.0.0" |
    And I have added sampling capabilities
    When I initialize the server
    Then the server should be able to request sampling from clients
    And handle sampling requests including:
      | method                    |
      | "sampling/createMessage"  |

  Scenario: Server initialization with comprehensive capabilities
    Given I have created a new MCP server with metadata
      | name         | version |
      | "test-server" | "1.0.0" |
    And I have added all available capabilities
    When I initialize the server
    Then the server should set up handlers for all supported methods
    And be ready to handle client requests across all capabilities
    And provide proper error responses for unsupported methods
