#!/bin/bash
# All process and privileged operations are fixtures; no installed app or service is touched.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
source "$REPO/Sources/ExitIPDiagnostics/cleanup-installation.sh"
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT

scenario() (
    local name=$1 expected=$2 result=0
    work="$fixture/$name"; mkdir -p "$work"
    app="$work/ExitIPMonitor.app"
    owner=$(/usr/bin/id -u)
    printf '1 0 Mon Oct 19 17:59:50 2026 /sbin/launchd\n' > "$work/table"
    : > "$work/signals"; : > "$work/privileged"; echo 0 > "$work/reads"
    add_process() { printf '%s %s Mon Oct 19 18:00:50 2026 %s/Contents/MacOS/ExitIPMonitor\n' "$1" "$2" "$3" >> "$work/table"; }
    case "$name" in
        fresh|partial|installed|unload_failure|delete_failure|job_inspection_failure|worker_failure) ;;
        translocated|invalid_translocation) add_process 456 "$owner" /private/var/folders/test/T/AppTranslocation/abc/d/ExitIPMonitor.app ;;
        wrong_owner) add_process 456 99999 "$app" ;;
        *) add_process 456 "$owner" "$app" ;;
    esac
    [ "$name" != multiple ] || add_process 457 "$owner" "$app"
    add_process 888 "$owner" "$work/Other.app"
    # Same executable basename at an unrelated location must also survive.
    add_process 889 "$owner" "$work/other/ExitIPMonitor.app"
    case "$name" in
        installed|unload_failure|delete_failure|job_inspection_failure|worker_failure)
            touch "$work/job-monitor" "$work/job-http" "$work/plist" "$work/http-plist" "$work/support" "$work/grant" ;;
        partial) touch "$work/plist" "$work/support" "$work/grant" ;;
    esac
    cleanup_pause() { :; }
    cleanup_process_table() {
        local reads
        reads=$(cat "$work/reads"); echo "$((reads + 1))" > "$work/reads"
        [ "$name" != inspection_failure ] || return 1
        if [ "$name" = reused_pid ] && [ "$reads" -gt 0 ]; then
            sed 's|18:00:50 2026 .*ExitIPMonitor.app/Contents/MacOS/ExitIPMonitor|18:01:00 2026 /usr/bin/sleep|' "$work/table"
        else
            cat "$work/table"
        fi
    }
    cleanup_translocation_matches() { [ "$name" = translocated ]; }
    cleanup_signal() {
        printf '%s %s\n' "$1" "$2" >> "$work/signals"
        [ "$name" != signal_denied ] || return 1
        [ "$name" != survives_kill ] || return 0
        if [ "$name" = hung ] && [ "$1" = TERM ]; then return 0; fi
        awk -v pid="$2" '$1 != pid' "$work/table" > "$work/next"
        mv "$work/next" "$work/table"
        if [ "$name" = respawn ]; then add_process 456 "$owner" "$app"; fi
    }
    cleanup_job_state() {
        [ "$name" != job_inspection_failure ] || return 2
        case "$1" in *-http) [ -f "$work/job-http" ] ;; *) [ -f "$work/job-monitor" ] ;; esac
    }
    cleanup_command_table() {
        if [ "$name" = worker_failure ]; then
            printf '55 /bin/bash %s/tailscale-verge.sh http\n' "$cleanup_support"
        else
            echo '1 /sbin/launchd'
        fi
    }
    component() {
        case "$1" in
            */LaunchDaemons/*-http.plist) echo http-plist ;;
            */LaunchDaemons/*.plist) echo plist ;;
            /etc/sudoers.d/*) echo grant ;;
            *) echo support ;;
        esac
    }
    cleanup_exists() { [ -f "$work/$(component "$1")" ]; }
    cleanup_privileged() {
        printf '%s\n' "$*" >> "$work/privileged"
        case "$1" in
            /bin/launchctl)
                [ "$name" != unload_failure ] || return 1
                case "$3" in *-http) rm -f "$work/job-http" ;; *) rm -f "$work/job-monitor" ;; esac ;;
            /bin/rm)
                [ "$name" != delete_failure ] || return 1
                rm -f "$work/$(component "$3")" ;;
            *) echo 'Unexpected privileged command' >&2; return 1 ;;
        esac
    }
    cleanup_main --app "$app" > "$work/log" 2>&1 || result=$?
    if [ "$result" != "$expected" ]; then cat "$work/log"; echo "FAIL $name: expected $expected got $result"; exit 1; fi
    ! grep -Eq ' (888|889)$' "$work/signals"
    case "$name" in
        fresh) [ ! -s "$work/signals" ] && [ ! -s "$work/privileged" ] ;;
        normal|multiple|translocated) ! grep -q KILL "$work/signals" ;;
        hung) grep -q 'TERM 456' "$work/signals"; grep -q 'KILL 456' "$work/signals" ;;
        reused_pid|wrong_owner|invalid_translocation|inspection_failure) [ ! -s "$work/signals" ] ;;
        installed|partial)
            [ "$(tail -1 "$work/privileged")" = '/bin/rm -f /etc/sudoers.d/exitipmonitor-tailscale-verge' ]
            : > "$work/privileged"
            cleanup_main --app "$app" >> "$work/log" 2>&1
            [ ! -s "$work/privileged" ] ;;
        unload_failure|delete_failure|job_inspection_failure|worker_failure) [ -f "$work/grant" ] ;;
    esac
    echo "PASS: cleanup $name"
)

for name in fresh normal multiple hung translocated reused_pid installed partial; do scenario "$name" 0; done
for name in wrong_owner invalid_translocation inspection_failure signal_denied survives_kill respawn \
    unload_failure delete_failure job_inspection_failure worker_failure; do scenario "$name" 1; done

# Exercise the real translocation signature gate independently of process fixtures.
(
    cleanup_app=/Applications/ExitIPMonitor.app
    cleanup_translocations=""
    bounded_command() {
        case "$2" in
            identity) echo "CDHash=${hash:-same}" ;;
            translocation-signature) [ "${valid:-1}" = 1 ] ;;
            *) return 1 ;;
        esac
    }
    target=/private/var/folders/test/T/AppTranslocation/test/d/ExitIPMonitor.app
    cleanup_translocation_matches "$target"
    cleanup_translocations=""; valid=0
    if cleanup_translocation_matches "$target"; then exit 1; fi
    valid=1
    bounded_command() {
        case "${*: -1}" in "$cleanup_app") echo CDHash=expected ;; *) echo CDHash=different ;; esac
    }
    if cleanup_translocation_matches "$target"; then exit 1; fi
    if cleanup_translocation_matches /tmp/ExitIPMonitor.app; then exit 1; fi
)
echo 'PASS: translocation requires matching identities and a verified sealed bundle'

# Native launchctl absence must be distinguished from permission and deadline errors.
(
    bounded_command() { echo 'Could not find service "example" in domain for system'; return "${code:-113}"; }
    result=0; cleanup_job_state example || result=$?; [ "$result" = 1 ]
    code=124; result=0; cleanup_job_state example 2>/dev/null || result=$?; [ "$result" = 2 ]
    code=1; result=0; cleanup_job_state example 2>/dev/null || result=$?; [ "$result" = 2 ]
)
echo 'PASS: service inspection errors cannot report successful removal'

# Native process enumeration and real signals, limited to disposable processes owned by this
# test. One ignores TERM, one exits normally, and another same-named bundle must survive.
(
    mkdir -p "$fixture/live/ExitIPMonitor.app/Contents/MacOS" "$fixture/unrelated/ExitIPMonitor.app/Contents/MacOS"
    cat > "$fixture/process.c" <<'EOF'
#include <signal.h>
#include <stdio.h>
#include <unistd.h>
int main(int argc, char **argv) {
    if (argc > 1) signal(SIGTERM, SIG_IGN);
    puts("ready"); fflush(stdout);
    for (;;) pause();
}
EOF
    binary="$fixture/live/ExitIPMonitor.app/Contents/MacOS/ExitIPMonitor"
    xcrun clang "$fixture/process.c" -o "$binary"
    cp "$binary" "$fixture/unrelated/ExitIPMonitor.app/Contents/MacOS/ExitIPMonitor"
    pids=()
    trap 'for pid in "${pids[@]:-}"; do [ -z "$pid" ] || kill -KILL "$pid" 2>/dev/null || true; done; wait 2>/dev/null || true' EXIT
    "$binary" > "$fixture/normal-ready" & normal=$!; pids+=("$normal")
    "$binary" ignore-term > "$fixture/hung-ready" & hung=$!; pids+=("$hung")
    "$fixture/unrelated/ExitIPMonitor.app/Contents/MacOS/ExitIPMonitor" > "$fixture/unrelated-ready" & unrelated=$!; pids+=("$unrelated")
    for file in normal-ready hung-ready unrelated-ready; do
        ticks=0
        until [ -s "$fixture/$file" ]; do
            [ "$ticks" -lt 50 ] || exit 1
            /bin/sleep 0.1; ticks=$((ticks + 1))
        done
    done
    cleanup_app="$fixture/live/ExitIPMonitor.app"
    cleanup_uid=$(/usr/bin/id -u); cleanup_translocations=""; cleanup_matches=()
    cleanup_stop_app > "$fixture/live-cleanup" 2>&1 || { cat "$fixture/live-cleanup"; exit 1; }
    wait "$normal" 2>/dev/null || true
    wait "$hung" 2>/dev/null || true
    ! kill -0 "$normal" 2>/dev/null
    ! kill -0 "$hung" 2>/dev/null
    kill -0 "$unrelated"
    grep -q "Sending TERM to verified app process $normal" "$fixture/live-cleanup"
    grep -q "Sending KILL to verified app process $hung" "$fixture/live-cleanup"
)
echo 'PASS: native process lookup stops normal and TERM-resistant processes; another bundle survives'
