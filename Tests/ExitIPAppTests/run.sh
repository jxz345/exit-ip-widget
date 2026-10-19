#!/bin/bash
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
output="${1:-$(mktemp -d)}"
mkdir -p "$output"
output="$(cd "$output" && pwd)"
export EXIT_IP_TEST_APP_GROUP="group.com.example.exitipmonitor.tests.$(/usr/bin/uuidgen)"
export EXIT_IP_LOG_DIRECTORY="$output/logs"
xcrun swiftc -swift-version 6 -parse-as-library -D EXIT_IP_TEST_HOST \
    "$REPO"/Sources/ExitIPShared/*.swift "$REPO"/Sources/ExitIPMonitorApp/*.swift \
    "$REPO/Tests/ExitIPAppTests/credential_test.swift" -o "$output/credential-tests"
"$output/credential-tests" "$output"
