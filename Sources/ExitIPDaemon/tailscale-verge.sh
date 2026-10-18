#!/bin/bash
# tailscale-verge.sh: Exit IP Monitor's optional Tailscale → Clash Verge provider. It keeps one
# Mihomo proxy-provider member, TS-NATIVE, bound to the current verified native Tailscale utun,
# and serves it at http://127.0.0.1:18766/provider.yaml (Mihomo polls it every 3 seconds).
#
#   tailscale-verge.sh monitor   root LaunchDaemon com.example.exitipmonitor.tailscale-verge.
#                                Every 2 s: verify the route, the Tailscale CLI address, and
#                                interface ownership, then write provider.yaml and state.
#   tailscale-verge.sh http      one HTTP connection on stdin/stdout, run as nobody by the
#                                socket-activated LaunchDaemon …tailscale-verge-http. It only
#                                reads the two files; it never runs a command.
#
# daemon.sh installs root-owned copies under /Library/Application Support/ExitIPMonitor and
# writes both plists. Behavior mirrors the reference provider (provider.py): the same checks,
# reason strings, response bodies, and a 12-second freshness guard that turns a stalled or dead
# monitor into Reject. Only the Tailscale CLI runs as the console user; with nobody at the
# console the result is Reject.
set -u
export LC_ALL=C
PATH=/usr/bin:/bin:/usr/sbin:/sbin

IDENTITY="tailscale-verge-live-v1"
QUAD100="100.100.100.100"
TAILSCALE_CLI="/Applications/Tailscale.app/Contents/MacOS/Tailscale"
ROUTE=/sbin/route IFCONFIG=/sbin/ifconfig SUDO=/usr/bin/sudo LOGGER=/usr/bin/logger
STATE_DIR="/Library/Application Support/ExitIPMonitor/TailscaleVerge"
LOG_TAG="exitip-tailscale-verge"
POLL_SECONDS=2 COMMAND_TIMEOUT=2 READ_TIMEOUT=3
STALE_AFTER=12 FUTURE_TOLERANCE=2
CONSOLE_OVERRIDE="" NOW_OVERRIDE=""

# Test hooks (Tests/ExitIPDaemonTests). Honored only for an ordinary user who opts in, never for
# root (the monitor) or nobody (the responder): under launchd the root-owned plists fix the
# environment, and these checks keep the hooks inert even if a variable were set.
if [ "${EXITIP_TSV_TEST:-}" = 1 ] && [ "$(/usr/bin/id -u)" != 0 ] && [ "$(/usr/bin/id -un)" != nobody ]; then
    ROUTE=${EXITIP_TSV_ROUTE:-$ROUTE} IFCONFIG=${EXITIP_TSV_IFCONFIG:-$IFCONFIG}
    SUDO=${EXITIP_TSV_SUDO:-$SUDO} LOGGER=${EXITIP_TSV_LOGGER:-$LOGGER}
    TAILSCALE_CLI=${EXITIP_TSV_CLI:-$TAILSCALE_CLI} STATE_DIR=${EXITIP_TSV_STATE_DIR:-$STATE_DIR}
    COMMAND_TIMEOUT=${EXITIP_TSV_TIMEOUT:-$COMMAND_TIMEOUT} READ_TIMEOUT=${EXITIP_TSV_READ_TIMEOUT:-$READ_TIMEOUT}
    POLL_SECONDS=${EXITIP_TSV_POLL:-$POLL_SECONDS}
    CONSOLE_OVERRIDE=${EXITIP_TSV_CONSOLE:-} NOW_OVERRIDE=${EXITIP_TSV_NOW:-}
fi

now() {
    if [ -n "$NOW_OVERRIDE" ]; then printf '%s\n' "$NOW_OVERRIDE"; else /bin/date +%s; fi
}

log() { "$LOGGER" -t "$LOG_TAG" "$*" 2>/dev/null; }

# The exact provider bytes Mihomo receives: Direct bound to a utun, or Reject.
provider_yaml() {
    printf 'proxies:\n  - name: TS-NATIVE\n'
    if [[ "${1:-}" =~ ^utun[0-9]+$ ]]; then
        printf '    type: direct\n    interface-name: %s\n    udp: true\n' "$1"
    else
        printf '    type: reject\n'
    fi
}

# ---------------------------------------------------------------------------------------------
# Monitor
# ---------------------------------------------------------------------------------------------

# run_bounded SECONDS OUTFILE COMMAND...: stdout to OUTFILE, stderr discarded, no shell.
# Returns the command's status, or 124 after SECONDS (TERM, then KILL). The function's stderr is
# discarded so bash's "Terminated" job notice for a killed command never reaches a log.
run_bounded() {
    local limit=$1 out=$2 pid ticks=0
    shift 2
    "$@" > "$out" 2>/dev/null < /dev/null &
    pid=$!
    while /bin/kill -0 "$pid" 2>/dev/null; do
        if [ "$ticks" -ge $((limit * 10)) ]; then
            /bin/kill -TERM "$pid" 2>/dev/null
            /bin/sleep 0.2
            /bin/kill -KILL "$pid" 2>/dev/null
            wait "$pid" 2>/dev/null
            return 124
        fi
        /bin/sleep 0.1
        ticks=$((ticks + 1))
    done
    wait "$pid"
} 2>/dev/null

# `route -n get` output → the utun interface of a specific (non-default) route, or failure.
parse_route() {
    /usr/bin/awk '
        /^[[:space:]]*destination:[[:space:]]*[^[:space:]]+[[:space:]]*$/ { d++; dest = $2 }
        /^[[:space:]]*interface:[[:space:]]*[^[:space:]]+[[:space:]]*$/ { i++; iface = $2 }
        END {
            if (d != 1 || i != 1) exit 1
            l = tolower(dest)
            if (l == "default" || l == "0" || l == "0.0.0.0" || l == "0.0.0.0/0" || l == "::" || l == "::/0") exit 1
            if (iface !~ /^utun[0-9]+$/) exit 1
            print iface
        }'
}

# CLI output → its single CGNAT (100.64.0.0/10) IPv4 address, written canonically, or failure.
parse_tailscale_ip() {
    local octet
    set -f
    # shellcheck disable=SC2086 # deliberate word splitting, like str.split()
    set -- $1
    set +f
    [ "$#" -eq 1 ] || return 1
    [[ "$1" =~ ^(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})$ ]] || return 1
    for octet in "${BASH_REMATCH[@]:1}"; do
        [ "$octet" -le 255 ] || return 1
    done
    [ "${BASH_REMATCH[1]}" = 100 ] && [ "${BASH_REMATCH[2]}" -ge 64 ] && [ "${BASH_REMATCH[2]}" -le 127 ] || return 1
    printf '%s\n' "$1"
}

# interface_owns_ip IFCONFIG_TEXT INTERFACE ADDRESS: the interface is UP and has that inet address.
interface_owns_ip() {
    printf '%s\n' "$1" | /usr/bin/awk -v ifc="$2" -v ip="$3" '
        !seen && index($0, ifc ":") == 1 {
            seen = 1
            rest = substr($0, length(ifc) + 2)
            if (rest ~ /^[[:space:]]*flags=[^<]*<[^>]*>/) {
                sub(/^[^<]*</, "", rest)
                sub(/>.*/, "", rest)
                n = split(rest, flags, ",")
                for (k = 1; k <= n; k++) {
                    flag = flags[k]
                    gsub(/^[[:space:]]+|[[:space:]]+$/, "", flag)
                    if (flag == "UP") up = 1
                }
            }
        }
        /^[[:space:]]*inet[[:space:]]+[^[:space:]]+/ { if ($2 == ip) owned = 1 }
        END { exit !(up && owned) }'
}

# Sets CONSOLE_UID, CONSOLE_NAME, CONSOLE_HOME for a real user at the console; fails at the
# login window (the console then belongs to root) or for system accounts.
console_user() {
    local uid name home
    if [ -n "$CONSOLE_OVERRIDE" ]; then
        read -r uid name home <<< "$CONSOLE_OVERRIDE"
    else
        uid=$(/usr/bin/stat -f %u /dev/console 2>/dev/null) || return 1
        name=$(/usr/bin/stat -f %Su /dev/console 2>/dev/null) || return 1
        if [ "$name" = "${CONSOLE_NAME:-}" ] && [ -n "${CONSOLE_HOME:-}" ]; then
            home=$CONSOLE_HOME
        else
            [[ "$name" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
            home=$(/usr/bin/dscl . -read "/Users/$name" NFSHomeDirectory 2>/dev/null | /usr/bin/awk 'NR == 1 { print $2 }')
        fi
    fi
    [[ "${uid:-}" =~ ^[0-9]+$ ]] && [ "$uid" -ge 501 ] || return 1
    [[ "${name:-}" =~ ^[A-Za-z0-9._-]+$ ]] && [[ "${home:-}" == /* ]] || return 1
    CONSOLE_UID=$uid CONSOLE_NAME=$name CONSOLE_HOME=$home
}

# step PHASE COMMAND...: one bounded command into $OUT; on failure sets REASON and fails.
step() {
    local phase=$1 status
    shift
    run_bounded "$COMMAND_TIMEOUT" "$OUT" "$@"
    status=$?
    case "$status" in
        0) return 0 ;;
        124) REASON="$phase-timeout" ;;
        *) REASON="$phase-unavailable" ;;
    esac
    return 1
}

output() { /usr/bin/head -c 65536 "$OUT"; }

# One verification pass (provider.py discover_interface). Sets IFACE (empty = Reject), REASON,
# and USED_UID. Only the Tailscale CLI drops to the console user, with that user's groups (the
# standalone client's LocalAPI token is root:admin 0640).
discover() {
    local iface address
    IFACE="" REASON="" USED_UID=""
    # A Mac without the standalone Tailscale app: Reject with a clear reason and run nothing else.
    [ -x "$TAILSCALE_CLI" ] || { REASON=tailscale-not-installed; return 0; }
    step route "$ROUTE" -n get "$QUAD100" || return 0
    iface=$(output | parse_route) || { REASON=no-tailscale-route; return 0; }
    console_user || { REASON=no-console-user; return 0; }
    USED_UID=$CONSOLE_UID
    step tailscale-cli "$SUDO" -n -u "#$CONSOLE_UID" -- /usr/bin/env -i \
        "HOME=$CONSOLE_HOME" "USER=$CONSOLE_NAME" "LOGNAME=$CONSOLE_NAME" \
        "PATH=/usr/bin:/bin:/usr/sbin:/sbin" LC_ALL=C TAILSCALE_BE_CLI=1 \
        "$TAILSCALE_CLI" ip -4 || return 0
    address=$(parse_tailscale_ip "$(output)") || { REASON=no-tailscale-ip; return 0; }
    step interface "$IFCONFIG" "$iface" || return 0
    interface_owns_ip "$(output)" "$iface" "$address" || { REASON=interface-not-owned-by-tailscale; return 0; }
    step route-recheck "$ROUTE" -n get "$QUAD100" || return 0
    [ "$(output | parse_route)" = "$iface" ] || { REASON=route-changed-during-check; return 0; }
    IFACE=$iface REASON=verified
}

# write_state EPOCH: provider.yaml (rewritten only when its bytes change) first, then state.
write_state() {
    local yaml current tmp state=reject
    [ -n "$IFACE" ] && state=direct
    yaml=$(provider_yaml "$IFACE"; printf x)
    current=$( { /bin/cat "$STATE_DIR/provider.yaml" 2>/dev/null; printf x; } )
    if [ "$current" != "$yaml" ]; then
        tmp="$STATE_DIR/.provider.yaml.$$"
        printf '%s' "${yaml%x}" > "$tmp" && /bin/mv -f "$tmp" "$STATE_DIR/provider.yaml"
    fi
    tmp="$STATE_DIR/.state.$$"
    printf 'state=%s\ninterface=%s\nreason=%s\nchecked=%s\nuid=%s\n' \
        "$state" "$IFACE" "$REASON" "$1" "$USED_UID" > "$tmp" && /bin/mv -f "$tmp" "$STATE_DIR/state"
}

monitor_main() {
    local current last=""
    umask 022
    if [ -L "$STATE_DIR" ] || ! /bin/mkdir -p "$STATE_DIR"; then
        log "state directory unavailable: $STATE_DIR"
        exit 1
    fi
    WORK=$(/usr/bin/mktemp -d "/tmp/exitip-tailscale-verge.XXXXXX") || exit 1
    OUT="$WORK/out"
    trap '/bin/rm -rf "$WORK"' EXIT
    trap 'exit 0' TERM INT
    while :; do
        discover
        write_state "$(now)"
        current="state=$([ -n "$IFACE" ] && echo direct || echo reject) interface=${IFACE:-none} reason=$REASON uid=${USED_UID:-none}"
        [ "$current" = "$last" ] || log "$current"
        last=$current
        /bin/sleep "$POLL_SECONDS"
    done
}

# ---------------------------------------------------------------------------------------------
# HTTP responder (nobody; reads two files; never runs a command)
# ---------------------------------------------------------------------------------------------

# Loads the state file into S_STATE, S_IFACE, S_REASON, S_AGE ("null" or whole seconds), applying
# the freshness guard. Any problem yields Reject.
load_state() {
    local key value checked="" state="" iface="" reason="" lines=0 at
    S_STATE=reject S_IFACE="" S_REASON=starting S_AGE=null
    [ -f "$STATE_DIR/state" ] && [ ! -L "$STATE_DIR/state" ] || return 0
    while IFS='=' read -r key value; do
        lines=$((lines + 1))
        case "$key" in
            state) state=$value ;;
            interface) iface=$value ;;
            reason) reason=$value ;;
            checked) checked=$value ;;
        esac
    done < <(/usr/bin/head -c 512 "$STATE_DIR/state")
    if [[ ! "$checked" =~ ^[1-9][0-9]{0,11}$ ]] || [[ ! "$reason" =~ ^[a-z0-9-]{1,64}$ ]] ||
       { [ "$state" != direct ] && [ "$state" != reject ]; }; then
        S_REASON=monitor-error
        return 0
    fi
    at=$(now)
    if [ "$checked" -gt $((at + FUTURE_TOLERANCE)) ]; then
        S_REASON=monitor-stale
        return 0
    fi
    S_AGE=$((at - checked))
    [ "$S_AGE" -ge 0 ] || S_AGE=0
    if [ "$S_AGE" -gt "$STALE_AFTER" ]; then
        S_REASON=monitor-stale
    elif [ "$state" = direct ] && [[ "$iface" =~ ^utun[0-9]+$ ]]; then
        S_STATE=direct S_IFACE=$iface S_REASON=$reason
    elif [ "$state" = direct ]; then
        S_REASON=invalid-interface
    else
        S_REASON=$reason
    fi
    S_AGE="$S_AGE.0"
}

http_date() { /bin/date -u '+%a, %d %b %Y %H:%M:%S GMT'; }

# send STATUS_LINE CONTENT_TYPE BODY HEAD_ONLY: the reference server's header order and bytes.
send() {
    local head
    head="HTTP/1.1 $1"$'\r\n'"Server: $IDENTITY "$'\r\n'"Date: $(http_date)"$'\r\n'
    head+="Content-Type: $2"$'\r\n'"Content-Length: ${#3}"$'\r\n'
    head+="Cache-Control: no-store"$'\r\n'"X-Content-Type-Options: nosniff"$'\r\n'"Connection: close"$'\r\n\r\n'
    if [ "$4" = 1 ]; then printf '%s' "$head"; else printf '%s%s' "$head" "$3"; fi
}

# The reference server's (Python http.server) error page, for 400 and 501.
send_error() {
    local code=$1 message=$2 explanation=$3 body
    body="<!DOCTYPE HTML>
<html lang=\"en\">
    <head>
        <meta charset=\"utf-8\">
        <style type=\"text/css\">
            :root {
                color-scheme: light dark;
            }
        </style>
        <title>Error response</title>
    </head>
    <body>
        <h1>Error response</h1>
        <p>Error code: $code</p>
        <p>Message: $message.</p>
        <p>Error code explanation: $code - $explanation.</p>
    </body>
</html>
"
    printf '%s' "HTTP/1.1 $code $message"$'\r\n'"Server: $IDENTITY "$'\r\n'"Date: $(http_date)"$'\r\n'
    printf '%s' "Connection: close"$'\r\n'"Content-Type: text/html;charset=utf-8"$'\r\n'"Content-Length: ${#body}"$'\r\n\r\n'"$body"
}

http_main() {
    local line header status count=0 size=0 method target head_only=0 expected file body iface
    exec 2>/dev/null
    IFS= read -r -t "$READ_TIMEOUT" line
    status=$?
    [ "$status" -le 128 ] || exit 0          # timed out: close without a response
    [ "$status" -eq 0 ] || [ -n "$line" ] || exit 0
    line=${line%$'\r'}
    while :; do
        header=""
        IFS= read -r -t "$READ_TIMEOUT" header
        status=$?
        [ "$status" -le 128 ] || exit 0
        header=${header%$'\r'}
        [ -n "$header" ] || break
        count=$((count + 1))
        size=$((size + ${#header}))
        if [ "$count" -gt 100 ] || [ "$size" -gt 8192 ]; then
            send_error 400 "Bad request" "Bad request syntax or unsupported method"
            exit 0
        fi
        [ "$status" -eq 0 ] || break
    done
    set -f
    # shellcheck disable=SC2086 # deliberate word splitting of the request line
    set -- $line
    set +f
    if [ "${#line}" -gt 8192 ] || [ "$#" -ne 3 ] || [[ ! "$1" =~ ^[A-Z]{1,16}$ ]] || [[ ! "$3" =~ ^HTTP/[0-9]\.[0-9]$ ]]; then
        send_error 400 "Bad request" "Bad request syntax or unsupported method"
        exit 0
    fi
    method=$1 target=$2
    case "$method" in
        GET) ;;
        HEAD) head_only=1 ;;
        *) send_error 501 "Unsupported method ('$method')" "Server does not support this operation"; exit 0 ;;
    esac
    load_state
    case "$target" in
        /provider.yaml)
            expected=$(provider_yaml "$S_IFACE"; printf x)
            if [ "$S_STATE" = direct ]; then
                # Serve the file only while it matches the fresh state; anything else is Reject.
                file=$( { /usr/bin/head -c 4096 "$STATE_DIR/provider.yaml" 2>/dev/null; printf x; } )
                [ "$file" = "$expected" ] || expected=$(provider_yaml ""; printf x)
            fi
            # text/plain so a browser shows it; Mihomo reads only the status and body.
            send "200 OK" "text/plain; charset=utf-8" "${expected%x}" "$head_only"
            ;;
        /status.json)
            if [ -n "$S_IFACE" ]; then iface="\"$S_IFACE\""; else iface=null; fi
            body="{\"checked_age_seconds\": $S_AGE, \"identity\": \"$IDENTITY\", \"interface\": $iface, \"reason\": \"$S_REASON\", \"state\": \"$S_STATE\"}"$'\n'
            send "200 OK" "application/json" "$body" "$head_only"
            ;;
        *)
            send "404 Not Found" "text/plain" $'Not found\n' "$head_only"
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" = "$0" ]]; then
    case "${1:-}" in
        monitor) monitor_main ;;
        http) http_main ;;
        *) echo "usage: tailscale-verge.sh monitor | http" >&2; exit 2 ;;
    esac
fi
