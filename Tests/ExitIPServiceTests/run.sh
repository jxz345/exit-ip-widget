#!/bin/bash
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
output="${1:-$REPO/.build/service-tests}"
mkdir -p "$output"
export EXIT_IP_LOG_DIRECTORY="$output/logs"
xcrun swiftc -swift-version 6 -parse-as-library -D EXIT_IP_SERVICE_TEST \
    "$REPO"/Sources/ExitIPShared/*.swift "$REPO"/Sources/ExitIPCore/*.swift \
    "$REPO"/Sources/ExitIPService/*.swift "$REPO/Tests/ExitIPServiceTests/service_test.swift" \
    -o "$output/service-tests"
"$output/service-tests" "$output"
