#!/bin/bash
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"

if [ "${1:-}" = --scenario ]; then
    scenario=$2; fixture=$3
    source "$REPO/Sources/ExitIPDiagnostics/diagnose-launch.sh"
    export EXIT_IP_LOG_DIRECTORY="$fixture/logs"
    mkdir -p "$EXIT_IP_LOG_DIRECTORY"
    process_alive() { [ "$1" = 12345 ]; }
    process_path() { printf '%s/Contents/MacOS/ExitIPMonitor\n' "$fixture/Test.app"; }
    same_file() { [ "$1" = "$2" ]; }
    trace_stream_command() {
        echo stream >> "$fixture/sequence"
        if [ "$scenario" = denied ]; then echo 'log: Operation not permitted'; return 1; fi
        echo 'syspolicyd: Waiting for user override authentication.'
        exec /bin/sleep 60
    }
    bounded_command() {
        local label=$2
        case "$label" in
            verify-signature) [ "$scenario" != invalid ] ;;
            open)
                grep -q stream "$fixture/sequence" # capture must precede the launch
                echo open >> "$fixture/sequence"
                [ "$scenario" != open_failure ] || return 7
                if [ "$scenario" = ready ] || [ "$scenario" = entered ]; then
                    ready=true; stage=app_ready
                    if [ "$scenario" = entered ]; then ready=false; stage=process_entered; fi
                    cat > "$EXIT_IP_LOG_DIRECTORY/launch-12345.json" <<EOF
{"pid":12345,"launch_id":"trace-test","started":$(date +%s),"updated":$(date +%s),"ready":$ready,"stage":"$stage","bundle_path":"$fixture/Test.app","version":"1.0","build":"6"}
EOF
                fi
                ;;
            security-history)
                echo 'syspolicyd: Waiting for user override authentication.'
                echo 'coreauthd: ERROR: Unable to get the SessionAgent endpoint, result = 2'
                ;;
            permission-denied) return 1 ;;
            *) return 0 ;;
        esac
    }
    collect_diagnostics() {
        echo '96K; _dyld_start (in dyld) + 0' > "$output/sample-12345.txt"
        if [ "$scenario" = denied ]; then
            diagnostic_command 1 permission-denied /usr/bin/false > "$output/denied.txt" 2>&1 || true
        fi
    }
    diagnose_main --app "$fixture/Test.app" --launch --trace --timeout "${4:-1}" --output "$fixture/report"
    exit $?
fi

fixture=$(mktemp -d)
fixture=$(cd "$fixture" && pwd -P)
trap 'rm -rf "$fixture"' EXIT
new_scenario() {
    mkdir -p "$fixture/$1/Test.app/Contents"
    cat > "$fixture/$1/Test.app/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict><key>CFBundleVersion</key><string>6</string><key>CFBundleShortVersionString</key><string>1.0</string></dict></plist>
EOF
}
assert_collector_stopped() {
    local pid
    pid=$(sed -n 's/.*External trace started before launch (pid \([0-9]*\)).*/\1/p' "$1/report/check.log")
    [ -n "$pid" ] && ! /bin/kill -0 "$pid" 2>/dev/null
}
for scenario in ready entered timeout open_failure invalid denied; do
    new_scenario "$scenario"
    status=0
    /bin/bash "$0" --scenario "$scenario" "$fixture/$scenario" > "$fixture/$scenario/console" 2>&1 || status=$?
    if [ "$scenario" = ready ] && [ "$status" != 0 ]; then cat "$fixture/$scenario/console"; fi
    if [ "$scenario" = ready ]; then
        [ "$status" = 0 ]
        grep -q '^result=ready$' "$fixture/$scenario/report/summary.txt"
        [ -s "$fixture/$scenario/report/ready.json" ]
    else
        [ "$status" = 1 ]
        ! grep -q '^result=ready$' "$fixture/$scenario/report/summary.txt"
    fi
    if [ "$scenario" = invalid ]; then
        [ ! -e "$fixture/$scenario/sequence" ]
        grep -q '^result=signature_not_verified$' "$fixture/$scenario/report/summary.txt"
    else
        assert_collector_stopped "$fixture/$scenario"
        grep -q 'SessionAgent endpoint' "$fixture/$scenario/report/summary.txt"
    fi
done
grep -q '^result=blocked_before_entry$' "$fixture/timeout/report/summary.txt"
grep -q '^result=entered_without_readiness$' "$fixture/entered/report/summary.txt"
grep -q 'Evidence incomplete' "$fixture/denied/report/summary.txt"
grep -q 'Live security log unavailable' "$fixture/denied/report/incomplete.txt"
grep -q 'permission-denied' "$fixture/denied/report/incomplete.txt"
echo 'PASS: capture precedes launch; readiness, timeout, open failure and permissions produce accurate reports and stop collectors'

# Cancel the diagnostic subshell itself, not its entire process group: cleanup must stop
# its owned collector without killing an unrelated process.
new_scenario cancelled
/bin/sleep 60 & unrelated=$!
/bin/bash "$0" --scenario cancelled "$fixture/cancelled" 20 > "$fixture/cancelled/console" 2>&1 & runner=$!
for _ in $(seq 1 50); do
    [ -f "$fixture/cancelled/sequence" ] && grep -q open "$fixture/cancelled/sequence" && break
    /bin/sleep 0.1
done
collector=$(sed -n 's/.*External trace started before launch (pid \([0-9]*\)).*/\1/p' "$fixture/cancelled/report/check.log")
monitor=$(/bin/ps -p "$collector" -o ppid= | tr -d ' ')
/bin/kill -TERM "$monitor"
status=0; wait "$runner" || status=$?
[ "$status" = 143 ]
assert_collector_stopped "$fixture/cancelled"
/bin/kill -0 "$unrelated"
/bin/kill -TERM "$unrelated"; wait "$unrelated" 2>/dev/null || true
grep -q '^result=cancelled$' "$fixture/cancelled/report/summary.txt"
echo 'PASS: cancellation writes a report and stops only the owned collector'

# Reusing a report directory could falsely classify a new failure using an old sample.
status=0
/bin/bash "$0" --scenario ready "$fixture/ready" > "$fixture/reused-output" 2>&1 || status=$?
[ "$status" = 2 ]
grep -q 'Output directory must be empty' "$fixture/reused-output"
echo 'PASS: an existing report cannot contaminate a new diagnostic run'
