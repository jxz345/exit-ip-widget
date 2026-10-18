#!/bin/bash
# Runs the daemon script checks: syntax, then the monitor, HTTP responder, and installer tests.
# Usage: bash Tests/ExitIPDaemonTests/run.sh   (as a normal user; nothing here touches the Mac)
set -euo pipefail
DIR=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$DIR/../.." && pwd)
for script in "$REPO"/Sources/ExitIPDaemon/*.sh "$DIR"/*.sh; do
    /bin/bash -n "$script"
done
echo "PASS: bash -n on the daemon scripts and tests"
for test in monitor_test.sh http_test.sh daemon_test.sh; do
    echo "== $test"
    /bin/bash "$DIR/$test"
done
echo "All daemon tests passed."
