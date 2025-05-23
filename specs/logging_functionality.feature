Feature: MCP Logging Functionality
  As a MCP Server implementer
  I want to use a configurable logging system
  So that I can monitor and debug the MCP server operations

  Scenario: Creating a logger with default settings
    When I create a new logger with default settings
    Then the logger should have Info level
    And colors should be enabled
    And timestamps should be enabled
    And no log file should be configured

  Scenario: Creating a logger with custom settings
    When I create a new logger with the following settings
      | level   | useColors | useTimestamp |
      | "Debug" | false     | false        |
    Then the logger should have Debug level
    And colors should be disabled
    And timestamps should be disabled
    And no log file should be configured

  Scenario: Configuring logger with a log file
    Given I have created a new logger
    When I configure the logger to write to a file
      | filePath           |
      | "/tmp/mcp_log.txt" |
    Then the logger should write log messages to the file
    And console output should still be produced
    And the log file should be properly closed when the logger is closed

  Scenario: Logging messages at different levels
    Given I have created a logger with Info level
    When I log messages at different levels
      | level     | message              |
      | "Debug"   | "Debug message"      |
      | "Info"    | "Info message"       |
      | "Warning" | "Warning message"    |
      | "Error"   | "Error message"      |
    Then Debug messages should be filtered out
    And Info, Warning, and Error messages should be logged
    And each message should have the appropriate formatting

  Scenario: Logging messages with formatting
    Given I have created a new logger
    When I log messages with parameters
      | level  | message                 | parameters          |
      | "Info" | "Value: {}"             | ["42"]              |
      | "Info" | "{} + {} = {}"          | ["2", "2", "4"]     |
    Then the messages should be properly formatted
    And parameter substitution should work correctly

  Scenario: Creating logger from environment variables
    Given environment variables are set
      | variable          | value     |
      | "MCP_LOG_LEVEL"   | "debug"   |
      | "MCP_LOG_COLORS"  | "false"   |
      | "MCP_LOG_TIMESTAMP" | "false" |
    When I create a logger from environment variables
    Then the logger should use the settings from environment variables
    And changes to environment variables should be reflected in new loggers

  Scenario: Default logger configuration
    Given a default logger exists
    When I change the default logger settings
    Then all logging through convenience methods should use the new settings
    And I should be able to restore the original default logger

  Scenario: Logger handles error conditions
    Given I have created a new logger
    When the logger encounters error conditions
      | condition                  |
      | "Invalid log file path"    |
      | "File write error"         |
    Then the logger should handle the errors gracefully
    And not crash the application
    And report the errors appropriately
