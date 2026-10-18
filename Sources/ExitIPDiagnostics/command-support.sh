#!/bin/bash
# Shared by the release installer, launch diagnostics, and daemon setup. Bash 3.2 compatible.
# No xtrace: command arguments can contain private data. Log descriptive step names instead.

step_log() { printf '%s %-6s %s\n' "$(/bin/date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" >&2; }

# BSD mktemp only randomizes trailing Xs (a trailing .log would produce a literal filename).
new_step_log() { /usr/bin/mktemp "$1/$2-XXXXXXXX"; }

# Each command gets its own process group, so a timed-out command's children cannot keep
# Homebrew's output pipe open. Only that group is terminated; unrelated jobs are untouched.
bounded_command() (
    set +e
    local limit=$1 label=$2 pid ticks=0 status started=$SECONDS
    shift 2
    step_log BEGIN "$label (timeout ${limit}s)"
    set -m
    "$@" &
    pid=$!
    set +m
    trap '/bin/kill -TERM -- "-$pid" 2>/dev/null; /bin/sleep 0.2; /bin/kill -KILL -- "-$pid" 2>/dev/null; exit 130' INT TERM
    while /bin/kill -0 "$pid" 2>/dev/null; do
        if [ "$ticks" -ge "$((limit * 10))" ]; then
            /bin/kill -TERM -- "-$pid" 2>/dev/null || true
            /bin/sleep 0.2
            /bin/kill -KILL -- "-$pid" 2>/dev/null || true
            wait "$pid" 2>/dev/null || true
            step_log ERROR "$label timed out after $((SECONDS - started))s (status 124)"
            exit 124
        fi
        /bin/sleep 0.1
        ticks=$((ticks + 1))
    done
    wait "$pid" 2>/dev/null
    status=$?
    step_log END "$label status=$status elapsed=$((SECONDS - started))s"
    exit "$status"
)
