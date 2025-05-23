# Model Context Protocol (MCP) Server SDK for Nim
#
# Tests for the MCP logger implementation.

import unittest, os, strutils, options
import ../src/mcp/logger

suite "Logger Creation Tests":
  test "Default logger creation":
    let logger = newLogger()
    
    check(logger.level == Info)
    check(logger.useColors == true)
    check(logger.useTimestamp == true)
    check(not isSome(logger.logFile))
  
  test "Custom logger creation":
    let logger = newLogger(Debug, false, false)
    
    check(logger.level == Debug)
    check(logger.useColors == false)
    check(logger.useTimestamp == false)
    check(not isSome(logger.logFile))

suite "Logger Configuration Tests":
  test "Setting log level":
    var logger = newLogger(Info)
    check(logger.level == Info)
    
    logger.level = Debug
    check(logger.level == Debug)
    
    logger.level = Warning
    check(logger.level == Warning)
    
    logger.level = Error
    check(logger.level == Error)
  
  test "Creating logger from environment variables":
    # Store original values
    let origLogLevel = getEnv("MCP_LOG_LEVEL")
    let origLogColors = getEnv("MCP_LOG_COLORS")
    let origLogTimestamp = getEnv("MCP_LOG_TIMESTAMP")
    let origLogFile = getEnv("MCP_LOG_FILE")
    
    try:
      # Set environment variables
      putEnv("MCP_LOG_LEVEL", "debug")
      putEnv("MCP_LOG_COLORS", "false")
      putEnv("MCP_LOG_TIMESTAMP", "false")
      putEnv("MCP_LOG_FILE", "test_log.txt")
      
      let logger = initLoggerFromEnv()
      
      check(logger.level == Debug)
      check(logger.useColors == false)
      check(logger.useTimestamp == false)
      check(logger.logFile.isSome)
      check(logger.logFile.get() == "test_log.txt")
      
      # Test with invalid log level
      putEnv("MCP_LOG_LEVEL", "invalid")
      let loggerWithInvalidLevel = initLoggerFromEnv()
      # Should default to Info
      check(loggerWithInvalidLevel.level == Info)
      
      # Test with empty log file
      putEnv("MCP_LOG_FILE", "")
      let loggerWithoutFile = initLoggerFromEnv()
      check(not loggerWithoutFile.logFile.isSome)
    finally:
      # Restore original values
      if origLogLevel != "":
        putEnv("MCP_LOG_LEVEL", origLogLevel)
      else:
        delEnv("MCP_LOG_LEVEL")
        
      if origLogColors != "":
        putEnv("MCP_LOG_COLORS", origLogColors)
      else:
        delEnv("MCP_LOG_COLORS")
        
      if origLogTimestamp != "":
        putEnv("MCP_LOG_TIMESTAMP", origLogTimestamp)
      else:
        delEnv("MCP_LOG_TIMESTAMP")
        
      if origLogFile != "":
        putEnv("MCP_LOG_FILE", origLogFile)
      else:
        delEnv("MCP_LOG_FILE")
        
      # Clean up test log file if it was created
      if fileExists("test_log.txt"):
        removeFile("test_log.txt")

suite "Logging Tests":
  setup:
    # Create a logger that doesn't output to console for clean test output
    let logger = newLogger(Debug, false, false)
  
  test "Log level filtering":
    # This test primarily checks that log filtering doesn't cause exceptions
    
    # Debug message (should be logged with Debug level)
    logger.log(Debug, "Debug message")
    
    # Debug message with Info level (should be filtered out)
    var infoLogger = newLogger(Info, false, false)
    infoLogger.log(Debug, "This debug message should be filtered")
    
    # Error message (should be logged with any level)
    infoLogger.log(Error, "Error message")
    
    # No assertions here, just making sure it doesn't crash
    check(true)
  
  test "Log message formatting":
    # This is primarily a visual test to ensure formatting works
    # but we can't easily test the output in a unit test
    
    # Simple message
    logger.log(Info, "Simple message")
    
    # Message with formatting
    logger.log(Info, "Formatted message: {}", "value")
    
    # Message with multiple format parameters
    logger.log(Info, "Multiple params: {}, {}, {}", "a", "b", "c")
    
    # Message with more placeholders than arguments (should leave remaining {} as is)
    logger.log(Info, "Not enough args: {}, {}, {}", "a", "b")
    
    # Test all level-specific methods
    logger.debug("Debug message")
    logger.info("Info message")
    logger.warning("Warning message")
    logger.error("Error message")
    
    # No assertions here, just making sure it doesn't crash
    check(true)
  
  test "Log file output":
    # Create a temporary log file
    let tempLogFile = "temp_test_log.txt"
    
    try:
      # Create a logger that outputs to a file
      let fileLogger = newLogger(
        Debug, 
        false, 
        false, 
        some(tempLogFile)
      )
      
      # Log some messages
      fileLogger.info("Test log message")
      fileLogger.error("Test error message")
      
      # Check that the file exists and contains the messages
      check(fileExists(tempLogFile))
      
      # Read the file content
      let content = readFile(tempLogFile)
      check(content.contains("Test log message"))
      check(content.contains("Test error message"))
    finally:
      # Clean up
      if fileExists(tempLogFile):
        removeFile(tempLogFile)

suite "Default Logger Tests":
  test "Default logger usage":
    # Store original default logger
    let origLogger = defaultLogger
    
    try:
      # Create a new default logger
      let newDefaultLogger = newLogger(Debug, false, false)
      setDefaultLogger(newDefaultLogger)
      
      # Use convenience methods
      debug("Debug message")
      info("Info message")
      warning("Warning message")
      error("Error message")
      
      # No assertions here, just making sure it doesn't crash
      check(true)
    finally:
      # Restore original default logger
      setDefaultLogger(origLogger)
  
  test "Default logger initialization from environment":
    # Store original values
    let origLogLevel = getEnv("MCP_LOG_LEVEL")
    let origLogger = defaultLogger
    
    try:
      # Set environment variable
      putEnv("MCP_LOG_LEVEL", "error")
      
      # Initialize default logger from environment
      initDefaultLoggerFromEnv()
      
      # Check that default logger has the expected level
      check(defaultLogger.level == Error)
    finally:
      # Restore original values
      if origLogLevel != "":
        putEnv("MCP_LOG_LEVEL", origLogLevel)
      else:
        delEnv("MCP_LOG_LEVEL")
      
      # Restore original default logger
      setDefaultLogger(origLogger)
