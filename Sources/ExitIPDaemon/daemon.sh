#!/bin/bash
# daemon.sh: install or remove Exit IP Monitor's optional Tailscale → Clash Verge provider, two
# LaunchDaemons that keep http://127.0.0.1:18766/provider.yaml bound to the current native
# Tailscale utun (see tailscale-verge.sh and README → Tailscale → Clash Verge provider).
#   sudo /bin/bash daemon.sh install   report whether Tailscale and Clash Verge Rev are present, copy
#                                      the script to a root-owned location, load the monitor, add
#                                      the removal grant, stop whatever holds port 18766, then load
#                                      the socket-activated responder
#   sudo /bin/bash daemon.sh remove    unload both, delete their files and the grant, and remember
#                                      the choice so Homebrew reinstalls don't turn it back on
#   /bin/bash daemon.sh status         show what is installed and the current state (no root needed)
# Homebrew runs `install` after every install and reinstall (cask postflight), unless the user ran
# `remove`. A Mac without Tailscale or Clash Verge Rev still gets the daemon; it then serves Reject
# with a reason the dashboard explains.
# The script is copied out of the source folder or app bundle on purpose: launchd must never run
# root code from a location the user can modify.
# Exit status: 0 done, 1 error, 2 usage, 3 monitor installed but port 18766 could not be freed
# (the responder was not installed).
set -uo pipefail
PATH=/usr/bin:/bin:/usr/sbin:/sbin

LABEL="com.example.exitipmonitor.tailscale-verge"
HTTP_LABEL="$LABEL-http"
PLIST="/Library/LaunchDaemons/$LABEL.plist"
HTTP_PLIST="/Library/LaunchDaemons/$HTTP_LABEL.plist"
DIR="/Library/Application Support/ExitIPMonitor"
SCRIPT="$DIR/tailscale-verge.sh"
STATE_DIR="$DIR/TailscaleVerge"
INSTALL_OWNER="-o root -g wheel"   # tests clear it to copy into a temporary folder
PORT=18766
# Lets `brew uninstall` remove the daemon without a password (see grant_line); like Sleepless's grant.
GRANT="/etc/sudoers.d/exitipmonitor-tailscale-verge"
# Written in the user's home by `remove`, deleted by `install` (as the user, never as root); the
# cask's postflight skips a Mac that has it, like Sleepless's service-off.
OPT_OUT="Library/Application Support/ExitIPMonitor/tailscale-verge-off"
TAILSCALE_APP="/Applications/Tailscale.app"
TAILSCALE_CLI="$TAILSCALE_APP/Contents/MacOS/Tailscale"
CLASH_VERGE_APP="/Applications/Clash Verge.app"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/command-support.sh" ]; then
    source "$SCRIPT_DIR/command-support.sh"
else
    source "$SCRIPT_DIR/../ExitIPDiagnostics/command-support.sh"
fi

run() { bounded_command 20 "${1##*/} ${2:-}" "$@"; }

# Succeeds when something accepts connections on 127.0.0.1:PORT. connect() rather than bind():
# on macOS a SO_REUSEADDR bind to 127.0.0.1 succeeds over another process's wildcard listener.
port_accepts() {
    local port=${1:-$PORT} pid ticks=0
    ( exec 3<> "/dev/tcp/127.0.0.1/$port" ) 2>/dev/null &
    pid=$!
    while /bin/kill -0 "$pid" 2>/dev/null; do
        if [ "$ticks" -ge 10 ]; then
            /bin/kill -KILL "$pid" 2>/dev/null
            wait "$pid" 2>/dev/null
            return 0    # neither accepted nor refused within 1 s: treat as occupied
        fi
        /bin/sleep 0.1
        ticks=$((ticks + 1))
    done
    wait "$pid"
}

# bootout returns before launchd finishes removing the job; an immediate bootstrap then fails
# with "5: Input/output error", so wait until `launchctl print` no longer finds it.
BOOTOUT_TICKS=100   # 0.2 s each
bootout_target() {
    local target=$1 ticks=0 started=$SECONDS status=0
    step_log BEGIN "Unload $target"
    run /bin/launchctl bootout "$target" >/dev/null 2>&1 || status=$?
    if [ "$status" = 124 ]; then
        step_log ERROR "Timed out unloading $target"
        return 1
    fi
    while true; do
        status=0
        run /bin/launchctl print "$target" >/dev/null 2>&1 || status=$?
        if [ "$status" = 124 ]; then
            step_log ERROR "Timed out inspecting $target"
            return 1
        fi
        [ "$status" = 0 ] || break
        if [ "$ticks" -ge "$BOOTOUT_TICKS" ] || [ "$((SECONDS - started))" -ge 20 ]; then
            echo "error: launchd did not unload $target within 20 seconds." >&2
            return 1
        fi
        /bin/sleep 0.2
        ticks=$((ticks + 1))
    done
    step_log END "Unloaded $target"
}

bootout_wait() { bootout_target "system/$1"; }

# listener_pids PORT: processes listening on TCP PORT on any address. launchd itself (pid 1, which
# holds the sockets of socket-activated jobs) and this script are never listed.
listener_pids() {
    local pid
    for pid in $(/usr/sbin/lsof -nP -iTCP:"$1" -sTCP:LISTEN -t 2>/dev/null | /usr/bin/sort -un); do
        [[ "$pid" =~ ^[0-9]+$ ]] && [ "$pid" -gt 1 ] && [ "$pid" != "$$" ] && echo "$pid"
    done
}

# launchd_job PID: prints DOMAIN/LABEL when PID is the main process of a launchd job, whose
# KeepAlive would restart it after a plain kill. launchd names the job in XPC_SERVICE_NAME, but
# children inherit that variable, so the job's own pid must match as well.
launchd_job() {
    local pid=$1 label uid domain domains
    label=$(/bin/ps -E -ww -o command= -p "$pid" 2>/dev/null | /usr/bin/tr ' ' '\n' |
        /usr/bin/sed -n 's/^XPC_SERVICE_NAME=//p' | /usr/bin/head -1)
    [[ "$label" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] && [ "$label" != 0 ] || return 1
    uid=$(/bin/ps -o uid= -p "$pid" 2>/dev/null | /usr/bin/tr -d ' ')
    [[ "$uid" =~ ^[0-9]+$ ]] || return 1
    if [ "$uid" = 0 ]; then domains="system"; else domains="gui/$uid user/$uid"; fi
    for domain in $domains; do
        if [ "$(run /bin/launchctl print "$domain/$label" 2>/dev/null |
                /usr/bin/awk '$1 == "pid" && $2 == "=" { print $3; exit }')" = "$pid" ]; then
            echo "$domain/$label"
            return 0
        fi
    done
    return 1
}

# stop_port_holders PORT: stops whatever listens on PORT so the responder can own it. A launchd
# job is disabled and booted out, so it is not started again (at login, at boot, or by
# KeepAlive); the command that allows it again is printed. Any other process gets TERM, then
# KILL after 5 seconds. Apple's own jobs are never stopped. Fails if the port is still in use.
stop_port_holders() {
    local port=$1 pid job command ticks
    for pid in $(listener_pids "$port"); do
        command=$(/bin/ps -o comm= -p "$pid" 2>/dev/null)
        if job=$(launchd_job "$pid"); then
            case "$job" in
                */com.apple.*) echo "error: port $port is held by Apple's $job; it is not stopped." >&2; return 1 ;;
            esac
            echo "Stopping launchd job $job (pid $pid, $command), which holds port $port, and disabling it."
            echo "  To allow it again: sudo launchctl enable $job"
            run /bin/launchctl disable "$job" >/dev/null 2>&1 || true
            bootout_target "$job" || return 1
        fi
        if /bin/kill -0 "$pid" 2>/dev/null; then
            echo "Stopping pid $pid ($command), which holds port $port."
            /bin/kill -TERM "$pid" 2>/dev/null
            ticks=0
            while /bin/kill -0 "$pid" 2>/dev/null && [ "$ticks" -lt 50 ]; do
                /bin/sleep 0.1
                ticks=$((ticks + 1))
            done
            /bin/kill -KILL "$pid" 2>/dev/null || true
        fi
    done
    ticks=0
    while port_accepts "$port"; do
        [ "$ticks" -lt 25 ] || return 1
        /bin/sleep 0.2
        ticks=$((ticks + 1))
    done
}

# first_check SINCE: waits up to 10 s for a monitor pass that finished at or after SINCE and prints it.
first_check() {
    local since=$1 ticks=0 checked
    while [ "$ticks" -lt 50 ]; do
        checked=$(/usr/bin/sed -n 's/^checked=//p' "$STATE_DIR/state" 2>/dev/null)
        if [[ "$checked" =~ ^[0-9]+$ ]] && [ "$checked" -ge "$since" ]; then
            echo "Monitor's first check: $(/usr/bin/grep -E '^(state|interface|reason)=' "$STATE_DIR/state" | /usr/bin/paste -sd ' ' -)"
            return 0
        fi
        /bin/sleep 0.2
        ticks=$((ticks + 1))
    done
    echo "warning: the monitor has not completed a check yet; see: daemon.sh status" >&2
}

# target_user: the login user the grant and opt-out marker belong to. SUDO_USER (set by Homebrew's
# sudo step and by manual sudo), else the console user; never root.
target_user() {
    local user=${SUDO_USER:-}
    if [ -z "$user" ] || [ "$user" = root ]; then
        user=$(/usr/bin/stat -f %Su /dev/console 2>/dev/null || true)
    fi
    [[ "$user" =~ ^[A-Za-z0-9._-]+$ ]] && [ "$user" != root ] && [ "$user" != loginwindow ] || return 1
    /usr/bin/id -u "$user" >/dev/null 2>&1 || return 1
    printf '%s\n' "$user"
}

user_home() {
    /usr/bin/dscl . -read "/Users/$1" NFSHomeDirectory 2>/dev/null | /usr/bin/awk 'NR == 1 { print $2 }'
}

# set_opt_out USER on|off: create or delete the opt-out marker as that user, so a symlink in the
# home folder can never redirect a root write.
set_opt_out() {
    local user=$1 state=$2 home
    home=$(user_home "$user")
    [[ "$home" == /* ]] || return 1
    if [ "$state" = on ]; then
        run /usr/bin/sudo -n -u "$user" -- /bin/mkdir -p "$home/${OPT_OUT%/*}" &&
            run /usr/bin/sudo -n -u "$user" -- /usr/bin/touch "$home/$OPT_OUT"
    else
        run /usr/bin/sudo -n -u "$user" -- /bin/rm -f "$home/$OPT_OUT"
    fi
}

# grant_line USER: exactly the commands `brew uninstall` needs to remove the daemon (and a restart).
# sudoers matches arguments literally, so nothing else is permitted; the plists are root-owned, so
# nothing can be loaded or started through it.
grant_line() {
    printf '%s ALL=(root) NOPASSWD: /bin/launchctl bootout system/%s, /bin/launchctl bootout system/%s, /bin/launchctl kickstart -k system/%s, /bin/rm -f %s, /bin/rm -f %s, /bin/rm -rf %s, /bin/rm -f %s\n' \
        "$1" "$LABEL" "$HTTP_LABEL" "$LABEL" "$PLIST" "$HTTP_PLIST" "${DIR// /\\ }" "$GRANT"
}

install_grant() {
    local tmp status
    tmp=$(/usr/bin/mktemp) || return 1
    grant_line "$1" > "$tmp"
    if ! /usr/sbin/visudo -cf "$tmp" >/dev/null 2>&1; then
        /bin/rm -f "$tmp"
        echo "error: the removal grant failed sudoers validation; it was not installed." >&2
        return 1
    fi
    # shellcheck disable=SC2086 # INSTALL_OWNER is deliberately split into options
    /usr/bin/install -m 0440 $INSTALL_OWNER "$tmp" "$GRANT"
    status=$?
    /bin/rm -f "$tmp"
    return "$status"
}

# preflight_report: what the provider depends on. Never fatal: without Tailscale the daemon serves
# Reject (reason tailscale-not-installed); without Clash Verge Rev nothing uses it yet.
preflight_report() {
    if [ -x "$TAILSCALE_CLI" ]; then
        echo "Tailscale: installed."
    else
        echo "Tailscale: not installed (expected $TAILSCALE_APP). The provider serves Reject until Tailscale is installed and connected."
    fi
    if [ -d "$CLASH_VERGE_APP" ]; then
        echo "Clash Verge Rev: installed."
    else
        echo "Clash Verge Rev: not installed (expected $CLASH_VERGE_APP). Nothing uses the provider until you install it and import the profile shown in Exit IP's dashboard."
    fi
}

monitor_plist() {
    cat <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>            <string>$LABEL</string>
    <key>ProgramArguments</key> <array><string>/bin/bash</string><string>$SCRIPT</string><string>monitor</string></array>
    <key>RunAtLoad</key>        <true/>
    <key>KeepAlive</key>        <true/>
    <key>ThrottleInterval</key> <integer>5</integer>
    <key>ProcessType</key>      <string>Background</string>
</dict>
</plist>
PLIST
}

# launchd owns the loopback socket and runs one responder per connection (inetd style) as nobody.
http_plist() {
    cat <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>              <string>$HTTP_LABEL</string>
    <key>ProgramArguments</key>   <array><string>/bin/bash</string><string>$SCRIPT</string><string>http</string></array>
    <key>UserName</key>           <string>nobody</string>
    <key>GroupName</key>          <string>nobody</string>
    <key>inetdCompatibility</key> <dict><key>Wait</key><false/></dict>
    <key>Sockets</key>
    <dict>
        <key>Listener</key>
        <dict>
            <key>SockNodeName</key>    <string>127.0.0.1</string>
            <key>SockServiceName</key> <string>$PORT</string>
            <key>SockFamily</key>      <string>IPv4</string>
            <key>SockType</key>        <string>stream</string>
        </dict>
    </dict>
</dict>
</plist>
PLIST
}

# install_plist GENERATOR DESTINATION LABEL
install_plist() {
    local tmp
    tmp="$(/usr/bin/mktemp)" || return 1
    "$1" > "$tmp" && /usr/bin/plutil -lint "$tmp" >/dev/null &&
        /usr/bin/install -m 0644 -o root -g wheel "$tmp" "$2"
    local status=$?
    /bin/rm -f "$tmp"
    [ "$status" -eq 0 ] || return 1
    run /bin/launchctl enable "system/$3" &&
        run /bin/launchctl bootstrap system "$2"
}

# copy_files: the root-owned copy of the script, and the folder for the files it writes.
copy_files() {
    # shellcheck disable=SC2086 # INSTALL_OWNER is deliberately split into options
    /usr/bin/install -d -m 0755 $INSTALL_OWNER "$DIR" "$STATE_DIR" &&
        /usr/bin/install -m 0755 $INSTALL_OWNER "$SCRIPT_DIR/tailscale-verge.sh" "$SCRIPT"
}

install_main() {
    local started user
    step_log BEGIN "Install Tailscale → Clash Verge services"
    [ -f "$SCRIPT_DIR/tailscale-verge.sh" ] || { echo "error: tailscale-verge.sh is missing next to daemon.sh." >&2; return 1; }
    user=$(target_user) || user=""
    preflight_report
    bootout_wait "$HTTP_LABEL" || return 1
    bootout_wait "$LABEL" || return 1
    step_log BEGIN "Copy root-owned service files"
    copy_files || return 1
    step_log END "Service files copied"
    started=$(/bin/date +%s)
    install_plist monitor_plist "$PLIST" "$LABEL" || { echo "error: could not load $LABEL." >&2; return 1; }
    echo "Monitor installed and running ($LABEL)."
    first_check "$started"
    if [ -n "$user" ]; then
        if install_grant "$user"; then
            echo "Removal grant installed for $user ($GRANT): brew uninstall removes the daemon without a password."
        fi
        set_opt_out "$user" off || echo "warning: could not clear the opt-out marker in $user's home." >&2
    else
        echo "warning: no login user found, so the removal grant was not installed." >&2
    fi
    if port_accepts "$PORT"; then
        echo "Port 127.0.0.1:$PORT is in use; stopping what holds it."
        if ! stop_port_holders "$PORT"; then
            /bin/rm -f "$HTTP_PLIST"
            echo "Port 127.0.0.1:$PORT is still in use, so the responder was not installed." >&2
            echo "Find the holder with: sudo lsof -nP -iTCP:$PORT -sTCP:LISTEN" >&2
            return 3
        fi
    fi
    install_plist http_plist "$HTTP_PLIST" "$HTTP_LABEL" || { echo "error: could not load $HTTP_LABEL." >&2; return 1; }
    echo "Responder installed ($HTTP_LABEL): http://127.0.0.1:$PORT/provider.yaml"
    step_log END "Service installation complete"
}

remove_main() {
    bootout_wait "$HTTP_LABEL" || return 1
    bootout_wait "$LABEL" || return 1
    run /bin/launchctl enable "system/$HTTP_LABEL" >/dev/null 2>&1 || true   # clear a disable override
    run /bin/launchctl enable "system/$LABEL" >/dev/null 2>&1 || true
    /bin/rm -f "$HTTP_PLIST" "$PLIST" "$SCRIPT" \
        "$STATE_DIR/provider.yaml" "$STATE_DIR/state" "$STATE_DIR"/.provider.yaml.* "$STATE_DIR"/.state.* || return 1
    /bin/rmdir "$STATE_DIR" 2>/dev/null || true
    /bin/rmdir "$DIR" 2>/dev/null || true
    /bin/rm -f "$GRANT" || return 1
    local user
    if user=$(target_user) && set_opt_out "$user" on; then
        echo "Tailscale → Clash Verge provider removed. It stays off when Homebrew reinstalls Exit IP Monitor; run install to turn it back on."
    else
        echo "Tailscale → Clash Verge provider removed."
    fi
}

status_main() {
    local label
    for label in "$LABEL" "$HTTP_LABEL"; do
        if /bin/launchctl print "system/$label" >/dev/null 2>&1; then
            echo "$label: loaded"
        else
            echo "$label: not loaded"
        fi
    done
    preflight_report
    if [ -f "$GRANT" ]; then echo "Removal grant: $GRANT"; else echo "Removal grant: not installed"; fi
    local user home
    if user=$(target_user) && home=$(user_home "$user") && [ -e "$home/$OPT_OUT" ]; then
        echo "Turned off by $user (reinstalls skip it): $home/$OPT_OUT"
    fi
    if [ -f "$STATE_DIR/state" ]; then
        echo "--- $STATE_DIR/state"
        /usr/bin/head -c 512 "$STATE_DIR/state"
        echo "--- $STATE_DIR/provider.yaml"
        /usr/bin/head -c 4096 "$STATE_DIR/provider.yaml" 2>/dev/null
    fi
}

daemon_main() {
    case "${1:-}" in
        install|remove)
            [ "$(/usr/bin/id -u)" -eq 0 ] || { echo "error: run as root (sudo /bin/bash daemon.sh $1)." >&2; return 1; }
            local log_dir=/Library/Logs/ExitIPMonitor log_file status
            [ ! -L "$log_dir" ] || { echo "error: log directory is a symlink." >&2; return 1; }
            /usr/bin/install -d -m 0755 -o root -g wheel "$log_dir" || return 1
            log_file=$(new_step_log "$log_dir" "daemon-$1") || return 1
            exec > >(/usr/bin/tee -a "$log_file") 2>&1
            step_log INFO "Daemon action=$1 uid=$(/usr/bin/id -u); log: $log_file"
            "$1_main"
            status=$?
            step_log END "Daemon action=$1 status=$status elapsed=${SECONDS}s; log: $log_file"
            return "$status"
            ;;
        status) status_main ;;
        *) echo "usage: daemon.sh install | remove | status" >&2; return 2 ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" = "$0" ]]; then
    daemon_main "$@"
    exit $?
fi
