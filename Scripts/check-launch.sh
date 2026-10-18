#!/bin/bash
exec /bin/bash "$(cd "$(dirname "$0")/.." && pwd)/Sources/ExitIPDiagnostics/diagnose-launch.sh" "$@"
