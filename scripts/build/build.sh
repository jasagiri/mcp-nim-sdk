#!/bin/bash
# Build script for power_assert_nim

# Load common environment settings and functions
SCRIPT_DIR="$(dirname "$0")"
source "${SCRIPT_DIR}/../../scripts/env/env.sh"
source "${SCRIPT_DIR}/../../scripts/common/common.sh"

# Setup clean exit with trap
set_cleanup_trap

log_info "Building power_assert_nim"

# Create build directory if it doesn't exist
ensure_dir "${BUILD_BIN}"

# Set build mode based on environment variable or default to release
BUILD_MODE=${BUILD_MODE:-release}
case "${BUILD_MODE}" in
  "release")
    BUILD_FLAGS="${NIM_RELEASE_FLAGS}"
    log_info "Building in RELEASE mode"
    ;;
  "debug")
    BUILD_FLAGS="${NIM_DEBUG_FLAGS}"
    log_info "Building in DEBUG mode"
    ;;
  *)
    log_warning "Unknown build mode: ${BUILD_MODE}. Using release mode."
    BUILD_FLAGS="${NIM_RELEASE_FLAGS}"
    ;;
esac

# Add any custom defines from environment variable
if [ -n "${DEFINES}" ]; then
  for define in ${DEFINES}; do
    BUILD_FLAGS="${BUILD_FLAGS} -d:${define}"
    log_info "Adding define: ${define}"
  done
fi

log_info "Building main module: ${MAIN_MODULE}"

# Execute the build with time measurement
time_command ${NIM_COMPILER} c ${BUILD_FLAGS} -o:"${BUILD_BIN}/${MAIN_MODULE}" "${SRC_DIR}/${MAIN_MODULE}.nim"

log_success "Build completed successfully!"

# Notify about the output location
log_info "Binary created at: ${BUILD_BIN}/${MAIN_MODULE}"

# Show file info if verbose mode
if [ "${VERBOSE}" = "true" ]; then
  if [ -f "${BUILD_BIN}/${MAIN_MODULE}" ]; then
    ls -lh "${BUILD_BIN}/${MAIN_MODULE}"
  fi
fi