#!/bin/bash
# Build all examples in the MCP Nim SDK

# Exit on error
set -e

# Make script directory the working directory
cd "$(dirname "$0")"
cd ../..

# Function to build an example
build_example() {
  local example_path="$1"
  echo "Building: $example_path"
  nim c "$example_path"
}

# Build examples by directory
echo "=== Building Base examples ==="
build_example "examples/base/simple_client.nim"
build_example "examples/base/simple_server.nim"

echo "=== Building HTTP examples ==="
build_example "examples/http/http_client.nim"
build_example "examples/http/http_server.nim"

echo "=== Building File Resource examples ==="
build_example "examples/fileresource/file_resource_client.nim"
build_example "examples/fileresource/file_resource_server.nim"

echo "=== Building Database examples ==="
build_example "examples/database/database_client.nim"
build_example "examples/database/database_server.nim"

echo "=== Building Roots examples ==="
build_example "examples/roots/roots_client.nim"
build_example "examples/roots/roots_server.nim"

echo "=== All examples built successfully ==="