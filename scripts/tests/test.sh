#!/bin/bash
# Test script for power_assert_nim

# Load common environment settings and functions
SCRIPT_DIR="$(dirname "$0")"
source "${SCRIPT_DIR}/../../scripts/env/env.sh"
source "${SCRIPT_DIR}/../../scripts/common/common.sh"

# Setup clean exit with trap
set_cleanup_trap

log_info "Running tests for power_assert_nim"

# Create build directory if it doesn't exist
ensure_dir "${BUILD_TESTS}"

# Check if prerequisite commands are available
check_command "${NIM_COMPILER}" || cleanup_and_exit 1 "Nim compiler not found"

# Get list of test files from environment or parameter
TEST_FILES_LIST=${TEST_FILES:-"test_power_assert.nim test_operators.nim test_custom_types.nim test_basic.nim"}

# Parse any test flags from environment
TEST_FLAGS=""
if [ "${COVERAGE_ENABLED}" = "true" ]; then
  TEST_FLAGS="${TEST_FLAGS} --passC:-fprofile-arcs --passC:-ftest-coverage"
  log_info "Coverage mode enabled"
fi

# Check if a specific test file is specified as an environment variable
if [ -n "${TEST_FILE}" ]; then
  # Run a specific test
  TEST_PATH="${TESTS_DIR}/${TEST_FILE}"
  
  if [ ! -f "${TEST_PATH}" ]; then
    log_error "Test file ${TEST_PATH} not found"
    cleanup_and_exit 1 "Test file not found"
  fi
  
  log_info "Running test: ${TEST_FILE}"
  time_command ${NIM_COMPILER} c -r ${TEST_FLAGS} -o:"${BUILD_TESTS}/$(basename "${TEST_FILE}" .nim)" "${TEST_PATH}"
  
  # Check test result
  if [ $? -eq 0 ]; then
    log_success "Test ${TEST_FILE} passed"
  else
    log_error "Test ${TEST_FILE} failed"
    cleanup_and_exit 1 "Test failed"
  fi
else
  # Run all tests
  log_info "Running all tests..."
  
  # Prepare a counter for test results
  TESTS_TOTAL=0
  TESTS_PASSED=0
  TESTS_FAILED=0
  
  for test_file in ${TEST_FILES_LIST}; do
    TESTS_TOTAL=$((TESTS_TOTAL + 1))
    TEST_PATH="${TESTS_DIR}/${test_file}"
    
    if [ ! -f "${TEST_PATH}" ]; then
      log_warning "Test file ${TEST_PATH} not found, skipping"
      continue
    fi
    
    log_info "Running test: ${test_file}"
    OUTPUT_PATH="${BUILD_TESTS}/$(basename "${test_file}" .nim)"
    
    # Run the test and capture result
    ${NIM_COMPILER} c -r ${TEST_FLAGS} -o:"${OUTPUT_PATH}" "${TEST_PATH}"
    TEST_RESULT=$?
    
    if [ ${TEST_RESULT} -eq 0 ]; then
      log_success "Test ${test_file} passed"
      TESTS_PASSED=$((TESTS_PASSED + 1))
    else
      log_error "Test ${test_file} failed with code ${TEST_RESULT}"
      TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
  done
  
  # Display test summary
  log_info "Test summary: ${TESTS_PASSED}/${TESTS_TOTAL} tests passed, ${TESTS_FAILED} failed"
  
  if [ ${TESTS_FAILED} -gt 0 ]; then
    log_error "Some tests failed"
    cleanup_and_exit 1 "Tests completed with failures"
  else
    log_success "All tests passed"
  fi
fi