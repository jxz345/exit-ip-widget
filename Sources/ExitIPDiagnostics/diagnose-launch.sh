#!/bin/bash
# Check a live main-thread heartbeat; --launch opens the app through LaunchServices first.
# A PID alone is never success. No quarantine removal, re-signing, or security settings changes.
# Usage: /bin/bash diagnose-launch.sh [--app PATH] [--launch] [--trace] [--timeout SECONDS] [--output DIR]
# --trace records external security/authentication logs before launch, even if the app cannot start.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/command-support.sh"
source "$SCRIPT_DIR/launch-trace.sh"

json_value() { /usr/bin/plutil -extract "$2" raw -o - "$1" 2>/dev/null; }

# Verify the identity, freshness, and liveness of the record. Functions are injectable in tests.
process_path() { /bin/ps -p "$1" -o comm= 2>/dev/null; }
process_alive() { /bin/kill -0 "$1" 2>/dev/null; }
same_file() { [ "$1" -ef "$2" ]; }
native_cdhash() {
    bounded_command 5 code-identity /usr/bin/codesign -d --arch "$(/usr/bin/uname -m)" --verbose=4 "$1" 2>&1 |
        /usr/bin/sed -n 's/^CDHash=//p'
}
verified_translocation() {
    local running=$1 requested=$2 expected actual
    case "$running" in
        /private/var/folders/*/T/AppTranslocation/*/d/ExitIPMonitor.app|/var/folders/*/T/AppTranslocation/*/d/ExitIPMonitor.app) ;;
        *) return 1 ;;
    esac
    expected=$(native_cdhash "$requested")
    actual=$(native_cdhash "$running")
    [ -n "$expected" ] && [ "$expected" = "$actual" ] || return 1
    bounded_command 10 verify-translocated-signature /usr/bin/codesign --verify --deep --strict "$running" >/dev/null 2>&1
}
startup_record_matches() {
    local file=$1 app=$2 build=$3 version=$4 since=$5 now=$6 pid updated started path running
    [ -f "$file" ] || return 1
    pid=$(json_value "$file" pid)
    updated=$(json_value "$file" updated)
    started=$(json_value "$file" started)
    [[ "$pid" =~ ^[0-9]+$ && "$updated" =~ ^[0-9]+$ && "$started" =~ ^[0-9]+$ ]] || return 1
    [ "$pid" -gt 1 ] && [ "$started" -ge "$since" ] && [ "$updated" -ge "$started" ] &&
        [ "$updated" -le "$now" ] || return 1
    [ "$(json_value "$file" build)" = "$build" ] &&
        [ "$(json_value "$file" version)" = "$version" ] &&
        [ -n "$(json_value "$file" launch_id)" ] || return 1
    process_alive "$pid" || return 1
    path=$(process_path "$pid")
    running=$(json_value "$file" bundle_path)
    same_file "$path" "$running/Contents/MacOS/ExitIPMonitor" || return 1
    same_file "$running" "$app" || verified_translocation "$running" "$app"
}
heartbeat_matches() {
    local updated
    startup_record_matches "$@" || return 1
    [ "$(json_value "$1" ready)" = true ] || return 1
    updated=$(json_value "$1" updated)
    [[ "$updated" =~ ^[0-9]+$ ]] && [ "$updated" -le "$6" ] && [ "$(($6 - updated))" -le 8 ]
}

collect_diagnostics() {
    local app=$1 output=$2 pid running
    step_log INFO "Collecting local diagnostics in $output (commands have individual deadlines)."
    [ -f "$output/identity.txt" ] || collect_launch_identity
    diagnostic_command 10 signature /usr/bin/codesign --verify --deep --strict --verbose=4 "$app" > "$output/signature.txt" 2>&1 || true
    # Restrict security output to this product. Do not copy provider logs or system-wide logs.
    diagnostic_command 10 security-log /usr/bin/log show --last 10m --style compact --info --predicate \
        '(process == "syspolicyd" OR process == "amfid" OR process == "taskgated-helper" OR process == "coreauthd") AND (eventMessage CONTAINS[c] "exitipmonitor" OR eventMessage CONTAINS[c] "syspolicyd" OR eventMessage CONTAINS "missing LA entitlement")' \
        > "$output/security.txt" 2>&1 || true
    for pid in $(/usr/bin/pgrep -x ExitIPMonitor 2>/dev/null); do
        running=$(process_path "$pid")
        running=${running%/Contents/MacOS/ExitIPMonitor}
        same_file "$running" "$app" || verified_translocation "$running" "$app" || continue
        diagnostic_command 5 "process-$pid" /bin/ps -p "$pid" -o pid,ppid,state,etime,comm > "$output/process-$pid.txt" 2>&1 || true
        diagnostic_command 8 "sample-$pid" /usr/bin/sample "$pid" 2 10 -file "$output/sample-$pid.txt" >> "$output/process-$pid.txt" 2>&1 || true
    done
    if /usr/bin/grep -q '_dyld_start.*+ 0' "$output"/sample-*.txt 2>/dev/null; then
        step_log ERROR "Process is blocked before application startup; inspect security.txt and the macOS approval dialog."
    fi
    step_log INFO "Diagnostics saved: $output. Review local paths before sharing."
}

diagnose_main() (
    # Subshell confines traps and diagnostic state when sourced by tests or another script.
    app=/Applications/ExitIPMonitor.app; launch=0; timeout=30; output=""; trace=0
    build=unknown; version=unknown; since=0; found=0; signature_valid=0
    trace_pid=""; trace_started=""; diagnostic_output=""
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --app|--timeout|--output)
                [ "$#" -ge 2 ] || { echo "Missing value for $1" >&2; return 2; }
                case "$1" in --app) app=$2 ;; --timeout) timeout=$2 ;; --output) output=$2 ;; esac
                shift 2 ;;
            --launch) launch=1; shift ;;
            --trace) trace=1; shift ;;
            --help|-h) sed -n '2,6p' "${BASH_SOURCE[0]}"; return 0 ;;
            *) echo "Unknown argument: $1" >&2; return 2 ;;
        esac
    done
    [[ "$timeout" =~ ^[0-9]+$ ]] && [ "$timeout" -ge 1 ] && [ "$timeout" -le 600 ] || { echo "Timeout must be 1–600 seconds." >&2; return 2; }
    [ -d "$app" ] || { echo "App not found: $app" >&2; return 2; }
    app="$(cd "$app" && pwd -P)"
    logs="${EXIT_IP_LOG_DIRECTORY:-$HOME/Library/Application Support/ExitIPMonitor/Logs}"
    umask 077
    if [ -z "$output" ]; then
        mkdir -p "$logs" || return 1
        output=$(/usr/bin/mktemp -d "$logs/launch-check-XXXXXXXX") || return 1
    else
        mkdir -p "$output" || return 1
        # Old evidence must not be mistaken for this run's readiness or process sample.
        [ -z "$(/bin/ls -A "$output")" ] || { echo "Output directory must be empty: $output" >&2; return 2; }
        /bin/chmod 700 "$output" || return 1
    fi
    diagnostic_output=$output
    trap 'finish_launch_diagnostics "$?"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    exec > >(/usr/bin/tee -a "$output/check.log") 2>&1
    step_log INFO "App: $app; diagnostics: $output"
    build=$(json_value "$app/Contents/Info.plist" CFBundleVersion)
    version=$(json_value "$app/Contents/Info.plist" CFBundleShortVersionString)
    [ -n "$build" ] && [ -n "$version" ] || { step_log ERROR "Missing bundle version."; return 1; }
    bounded_command 10 verify-signature /usr/bin/codesign --verify --deep --strict "$app" > "$output/verification.txt" 2>&1 || {
        step_log ERROR "Invalid signature. See $output/verification.txt"; return 1;
    }
    signature_valid=1
    if [ "$trace" = 1 ]; then
        collect_launch_identity
        start_launch_trace
    fi
    if [ "$launch" = 1 ]; then
        # Do not mistake an older copy of the same name for this launch. Opening an already
        # running healthy copy is supported, but it must still produce a recent heartbeat.
        for pid in $(/usr/bin/pgrep -x ExitIPMonitor 2>/dev/null); do
            file=$(process_path "$pid")
            file=${file%/Contents/MacOS/ExitIPMonitor}
            if same_file "$file" "$app" || verified_translocation "$file" "$app"; then found=1; fi
        done
        [ "$found" = 1 ] || since=$(/bin/date +%s)
        bounded_command 10 open /usr/bin/open "$app" || { collect_diagnostics "$app" "$output"; return 1; }
    fi
    start=$SECONDS
    step_log INFO "Waiting up to ${timeout}s for version $version ($build) and a live main-thread heartbeat."
    while [ "$((SECONDS - start))" -lt "$timeout" ]; do
        now=$(/bin/date +%s)
        for file in "$logs"/launch-*.json; do
            if startup_record_matches "$file" "$app" "$build" "$version" "$since" "$now"; then
                /bin/cp "$file" "$output/startup-$(json_value "$file" pid).json"
            fi
            if heartbeat_matches "$file" "$app" "$build" "$version" "$since" "$now"; then
                /bin/cp "$file" "$output/ready.json"
                step_log PASS "App ready: version $version ($build), pid $(json_value "$file" pid), launch $(json_value "$file" launch_id)."
                return 0
            fi
        done
        if [ "$(((SECONDS - start) % 5))" = 0 ]; then
            step_log WAIT "No fresh readiness response yet; complete any macOS Open Anyway/authentication prompt."
        fi
        /bin/sleep 1
    done
    step_log ERROR "App did not become ready within ${timeout}s; a running PID is not proof of startup."
    collect_diagnostics "$app" "$output"
    return 1
)

if [[ "${BASH_SOURCE[0]}" = "$0" ]]; then diagnose_main "$@"; exit $?; fi
