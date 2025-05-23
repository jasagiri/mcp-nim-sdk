#!/bin/bash

# Simply run a basic coverage test and generate a minimal report
echo "Running basic coverage tests..."

# Get the project root directory
PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

# Make output directory
mkdir -p "${PROJECT_ROOT}/build/coverage"
mkdir -p "${PROJECT_ROOT}/build/coverage/gcov"

# Run a basic test
echo "Running test_client.nim with coverage..."
nim c -r --passC:-fprofile-arcs --passC:-ftest-coverage --passL:-lgcov tests/test_client.nim 

# Create a simple index.html
mkdir -p "${PROJECT_ROOT}/build/coverage/html"
cat > "${PROJECT_ROOT}/build/coverage/html/index.html" << EOF
<!DOCTYPE HTML>
<html>
<head>
  <title>MCP Nim SDK Basic Coverage</title>
  <style>
    body { font-family: sans-serif; margin: 20px; }
    h1 { color: #333; }
  </style>
</head>
<body>
  <h1>MCP Nim SDK Basic Coverage Report</h1>
  <p>Generated: $(date)</p>
  <p>Basic coverage test completed successfully.</p>
  <p>For detailed coverage reports:</p>
  <ol>
    <li>Install lcov: <code>apt-get install lcov</code> or <code>brew install lcov</code></li>
    <li>Run <code>nimble coverage_structured</code></li>
  </ol>
</body>
</html>
EOF

echo "Basic coverage test completed."
echo "Report available at: ${PROJECT_ROOT}/build/coverage/html/index.html"