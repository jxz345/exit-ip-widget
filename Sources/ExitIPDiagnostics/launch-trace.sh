#!/bin/bash
# External launch evidence: this runs even when Gatekeeper stops the app before main().
# Keep Apple's default privacy redaction; never read Keychain or provider configuration.

TRACE_PREDICATE='(process == "syspolicyd" AND (subsystem BEGINSWITH "com.apple.syspolicy" OR subsystem == "com.apple.launchservices" OR subsystem == "com.apple.LocalAuthentication")) OR (process == "coreauthd" AND (subsystem == "com.apple.LocalAuthentication" OR subsystem == "com.apple.coreauthd" OR subsystem == "com.apple.login")) OR (process == "authd" AND subsystem == "com.apple.Authorization") OR (process == "CoreServicesUIAgent" AND subsystem == "com.apple.launchservices") OR ((process == "amfid" OR process == "taskgated-helper") AND eventMessage CONTAINS[c] "exitipmonitor")'

diagnostic_command() {
    local label=$2 status
    bounded_command "$@"
    status=$?
    if [ "$status" -ne 0 ]; then
        printf '%s: unavailable or incomplete (exit %s); see its report.\n' "$label" "$status" >> "$diagnostic_output/incomplete.txt"
    fi
    return "$status"
}

trace_stream_command() { exec /usr/bin/log stream --style compact --level info --predicate "$TRACE_PREDICATE"; }

start_launch_trace() {
    trace_started=$(/bin/date '+%Y-%m-%d %H:%M:%S')
    # Only this owned child is stopped. A file-size limit also bounds unusually busy logs.
    (ulimit -f 8192; trace_stream_command) > "$diagnostic_output/security-stream.txt" 2>&1 &
    trace_pid=$!
    step_log INFO "External trace started before launch (pid $trace_pid); macOS approval can be completed normally."
    /bin/sleep 0.2
    if ! /bin/kill -0 "$trace_pid" 2>/dev/null; then
        trace_status=0; wait "$trace_pid" || trace_status=$?
        printf 'Live security log unavailable (exit %s); see security-stream.txt.\n' "$trace_status" >> "$diagnostic_output/incomplete.txt"
        trace_pid=""
    fi
}

stop_launch_trace() {
    local exit_status=${1:-0}
    [ -n "$trace_pid" ] || return 0
    if /bin/kill -0 "$trace_pid" 2>/dev/null; then
        /bin/kill -TERM "$trace_pid" 2>/dev/null || true
        # log normally exits immediately. Bound cleanup even if the collector is stuck.
        local attempts=0
        while /bin/kill -0 "$trace_pid" 2>/dev/null && [ "$attempts" -lt 10 ]; do
            /bin/sleep 0.1
            attempts=$((attempts + 1))
        done
        /bin/kill -KILL "$trace_pid" 2>/dev/null || true
    elif [ "$exit_status" != 130 ] && [ "$exit_status" != 143 ]; then
        printf 'Live security log ended before capture completed; see security-stream.txt.\n' >> "$diagnostic_output/incomplete.txt"
    fi
    wait "$trace_pid" 2>/dev/null || true
    trace_pid=""
}

collect_launch_identity() {
    local arch
    diagnostic_command 5 system /usr/bin/sw_vers > "$diagnostic_output/system.txt" 2>&1 || true
    for arch in arm64 x86_64; do
        diagnostic_command 5 "signature-$arch" /usr/bin/codesign -dvvv --arch "$arch" "$app" >> "$diagnostic_output/identity.txt" 2>&1 || true
    done
    diagnostic_command 5 attributes /usr/bin/xattr -lrx "$app" > "$diagnostic_output/attributes.txt" 2>&1 || true
}

write_launch_summary() {
    local status=$1 file result=not_ready observation=unknown evaluation=none_recorded
    if [ "$status" = 0 ]; then
        observation=ready
    elif /bin/ls "$diagnostic_output"/startup-*.json >/dev/null 2>&1; then
        observation=entered_without_readiness
    elif /usr/bin/grep -q '_dyld_start.*+ 0' "$diagnostic_output"/sample-*.txt 2>/dev/null; then
        observation=sampled_before_entry
    fi
    if /usr/bin/grep -hiE 'waiting on another evaluation.*(com\.example\.exitipmonitor|ExitIPMonitor\.app)' \
        "$diagnostic_output"/security*.txt >/dev/null 2>&1; then
        evaluation=waiting_on_other_evaluation
    elif /usr/bin/grep -hiE 'waiting on another evaluation.*\(bundle_id: (\(null\)|<private>)\)' \
        "$diagnostic_output"/security*.txt >/dev/null 2>&1; then
        evaluation=unattributed_wait_observed
    fi
    if [ "$status" = 0 ]; then
        result=ready
    elif [ "$status" = 130 ] || [ "$status" = 143 ]; then
        result=cancelled
    elif [ "$signature_valid" != 1 ]; then
        result=signature_not_verified
    elif [ "$observation" = entered_without_readiness ]; then
        result=entered_without_readiness
    elif /usr/bin/grep -q '_dyld_start.*+ 0' "$diagnostic_output"/sample-*-final.txt 2>/dev/null; then
        # An early sample can be a transient startup state. Only the final sample
        # establishes that the failed check still found the process before entry.
        result=blocked_before_entry
    fi
    {
        printf 'result=%s\napp=%s\nversion=%s\nbuild=%s\nexit_status=%s\n' "$result" "$app" "$version" "$build" "$status"
        printf 'signature_verified=%s\ntrace_requested=%s\n' "$signature_valid" "$trace"
        printf 'startup_observation=%s\nevaluation_observation=%s\n' "$observation" "$evaluation"
        if [ -s "$diagnostic_output/incomplete.txt" ]; then
            printf '\nEvidence incomplete:\n'; /bin/cat "$diagnostic_output/incomplete.txt"
        fi
        for file in "$diagnostic_output"/startup-*.json; do
            [ -f "$file" ] || continue
            printf '\nStartup record: %s\n' "${file##*/}"; /bin/cat "$file"; printf '\n'
        done
        printf '\nAuthentication observations (not a root-cause verdict):\n'
        /usr/bin/grep -hE 'Waiting for user override authentication|Getting auth to allow override|handle prompt response|SessionAgent endpoint|evaluatePolicy.*returned' \
            "$diagnostic_output"/security*.txt 2>/dev/null | /usr/bin/tail -n 40 || true
        printf '\nEvaluation observations (identity may be absent; not a root-cause verdict):\n'
        /usr/bin/grep -hi 'waiting on another evaluation' \
            "$diagnostic_output"/security*.txt 2>/dev/null | /usr/bin/tail -n 10 || true
        printf '\nReady requires a matching, live main-thread heartbeat. Missing logs do not prove authentication failed.\n'
    } > "$diagnostic_output/summary.txt"
}

finish_launch_diagnostics() {
    local status=$1
    trap - EXIT INT TERM
    if { [ "$status" = 130 ] || [ "$status" = 143 ]; } && [ "$signature_valid" = 1 ]; then
        collect_process_evidence "$app" "$diagnostic_output" cancelled || true
    fi
    stop_launch_trace "$status" 2>/dev/null
    if [ "$trace" = 1 ] && [ -n "$trace_started" ]; then
        # Backfill the exact capture window, including events emitted while log stream starts.
        # Only security/authentication services are included; unrelated events in this short
        # window can appear, so reports remain local and retain default system redaction.
        (ulimit -f 8192; diagnostic_command 10 security-history /usr/bin/log show --start "$trace_started" \
            --end "$(/bin/date '+%Y-%m-%d %H:%M:%S')" --style compact --info --predicate "$TRACE_PREDICATE") \
            > "$diagnostic_output/security-history.txt" 2>&1 || true
    fi
    write_launch_summary "$status"
    step_log INFO "Report: $diagnostic_output/summary.txt"
    exit "$status"
}
