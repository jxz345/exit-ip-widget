#!/bin/bash
# Exercises daemon.sh's installer helpers without touching launchd: the connect() port probe,
# waiting for bootout, the generated plists, the removal grant, the opt-out marker, the preflight
# report, and refusing to install without root.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/../.." && pwd)
DAEMON="$REPO/Sources/ExitIPDaemon/daemon.sh"
[ "$(id -u)" != 0 ] || { echo "Run as a normal user." >&2; exit 1; }
FIXTURE=$(mktemp -d)
LISTENER=""
cleanup() { [ -z "$LISTENER" ] || kill "$LISTENER" 2>/dev/null || true; /bin/rm -rf "$FIXTURE"; }
trap cleanup EXIT
# shellcheck source=/dev/null
source "$DAEMON"
set +e

# A wildcard SO_REUSEADDR listener: a 127.0.0.1 bind() can succeed over it on macOS, so the
# installer must detect it with connect().
/usr/bin/python3 -c '
import socket, sys, time
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("0.0.0.0", 0)); s.listen()
print(s.getsockname()[1], flush=True)
time.sleep(30)' > "$FIXTURE/port" &
LISTENER=$!
for _ in $(seq 1 50); do [ -s "$FIXTURE/port" ] && break; sleep 0.1; done
busy=$(cat "$FIXTURE/port")
port_accepts "$busy" || { echo "FAIL: a wildcard listener was not detected"; exit 1; }
echo "PASS: the probe detects a wildcard listener on port $busy"
kill "$LISTENER"; wait "$LISTENER" 2>/dev/null; LISTENER=""
free=$(/usr/bin/python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
if port_accepts "$free"; then echo "FAIL: a free port was reported busy"; exit 1; fi
echo "PASS: the probe reports a free port as free"

# bootout_wait: polls `launchctl print` until the job is gone, with a deadline.
run() {
    echo "$*" >> "$FIXTURE/launchctl"
    case "$2" in
        bootout) return 0 ;;
        print) n=$(( $(cat "$FIXTURE/prints" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$FIXTURE/prints"; [ "$n" -le "$LOADED_FOR" ] ;;
    esac
}
LOADED_FOR=3
rm -f "$FIXTURE/prints" "$FIXTURE/launchctl"
bootout_wait "$LABEL" || { echo "FAIL: bootout_wait gave up on a job that unloaded"; exit 1; }
[ "$(cat "$FIXTURE/prints")" = 4 ] || { echo "FAIL: bootout_wait returned before the job was gone"; exit 1; }
head -1 "$FIXTURE/launchctl" | grep -qx "/bin/launchctl bootout system/$LABEL" || { echo "FAIL: bootout target"; exit 1; }
echo "PASS: bootout_wait waits until launchd no longer lists the job"
LOADED_FOR=1000 BOOTOUT_TICKS=3
rm -f "$FIXTURE/prints"
if bootout_wait "$LABEL" 2>/dev/null; then echo "FAIL: bootout_wait ignored its deadline"; exit 1; fi
echo "PASS: bootout_wait fails after its deadline"
unset -f run
run() { "$@"; }

# Both plists are valid and carry the fixed, root-owned paths.
monitor_plist > "$FIXTURE/monitor.plist"
http_plist > "$FIXTURE/http.plist"
plutil -lint "$FIXTURE/monitor.plist" "$FIXTURE/http.plist" >/dev/null || { echo "FAIL: plist syntax"; exit 1; }
value() { /usr/bin/plutil -extract "$2" raw -o - "$FIXTURE/$1.plist"; }
[ "$(value monitor ProgramArguments.0)" = /bin/bash ] && [ "$(value monitor ProgramArguments.1)" = "/Library/Application Support/ExitIPMonitor/tailscale-verge.sh" ] &&
    [ "$(value monitor ProgramArguments.2)" = monitor ] && [ "$(value monitor KeepAlive)" = true ] && [ "$(value monitor RunAtLoad)" = true ] ||
    { echo "FAIL: monitor plist"; exit 1; }
! /usr/bin/plutil -extract UserName raw -o - "$FIXTURE/monitor.plist" >/dev/null 2>&1 || { echo "FAIL: monitor must run as root"; exit 1; }
[ "$(value http ProgramArguments.2)" = http ] && [ "$(value http UserName)" = nobody ] && [ "$(value http GroupName)" = nobody ] &&
    [ "$(value http inetdCompatibility.Wait)" = false ] && [ "$(value http Sockets.Listener.SockNodeName)" = 127.0.0.1 ] &&
    [ "$(value http Sockets.Listener.SockServiceName)" = 18766 ] && [ "$(value http Sockets.Listener.SockFamily)" = IPv4 ] ||
    { echo "FAIL: responder plist"; exit 1; }
echo "PASS: the monitor runs as root (KeepAlive); the responder is a 127.0.0.1:18766 socket job run as nobody"

# Taking the port over: stop_port_holders stops whatever listens, and a launchd job is disabled
# and booted out first so KeepAlive cannot restart it. launchctl is stubbed; the listeners are real.
listen() { # XPC_SERVICE_NAME → starts a 127.0.0.1 listener; sets HOLDER (pid) and HOLDER_PORT
    rm -f "$FIXTURE/holder-port"
    XPC_SERVICE_NAME="$1" /usr/bin/python3 -c '
import socket, time
s = socket.socket(); s.bind(("127.0.0.1", 0)); s.listen()
print(s.getsockname()[1], flush=True)
time.sleep(60)' > "$FIXTURE/holder-port" &
    HOLDER=$!
    disown "$HOLDER"   # stopped by the code under test; no job notice
    for _ in $(seq 1 50); do [ -s "$FIXTURE/holder-port" ] && break; sleep 0.1; done
    HOLDER_PORT=$(cat "$FIXTURE/holder-port")
    LISTENER=$HOLDER
}
run() {
    echo "$*" >> "$FIXTURE/launchctl"
    case "$2" in
        print) [ "$3" = "$JOB_TARGET" ] && [ ! -e "$FIXTURE/booted-out" ] && printf '%s = {\n\tpid = %s\n}\n' "$3" "$JOB_PID" ;;
        bootout) touch "$FIXTURE/booted-out" ;;
    esac
}
reset_launchctl() { rm -f "$FIXTURE/launchctl" "$FIXTURE/booted-out"; touch "$FIXTURE/launchctl"; }
me=$(id -u)

listen 0
reset_launchctl; JOB_TARGET=none JOB_PID=0
[ "$(listener_pids "$HOLDER_PORT")" = "$HOLDER" ] || { echo "FAIL: listener_pids did not find the holder"; exit 1; }
stop_port_holders "$HOLDER_PORT" > /dev/null || { echo "FAIL: a plain listener was not stopped"; exit 1; }
! kill -0 "$HOLDER" 2>/dev/null && ! port_accepts "$HOLDER_PORT" || { echo "FAIL: plain listener still running"; exit 1; }
! grep -qE 'disable|bootout' "$FIXTURE/launchctl" || { echo "FAIL: a plain process was treated as a launchd job"; exit 1; }
echo "PASS: a plain process holding the port is stopped"

listen test.exitip.parent-app
reset_launchctl; JOB_TARGET="gui/$me/test.exitip.parent-app" JOB_PID=1234567
stop_port_holders "$HOLDER_PORT" > /dev/null || { echo "FAIL: inherited-label listener was not stopped"; exit 1; }
! kill -0 "$HOLDER" 2>/dev/null || { echo "FAIL: inherited-label listener still running"; exit 1; }
! grep -qE 'disable|bootout' "$FIXTURE/launchctl" || { echo "FAIL: a job whose pid differs was disabled"; exit 1; }
echo "PASS: an inherited XPC_SERVICE_NAME alone never disables that job"

listen test.exitip.keepalive
reset_launchctl; JOB_TARGET="gui/$me/test.exitip.keepalive" JOB_PID=$HOLDER
out=$(stop_port_holders "$HOLDER_PORT") || { echo "FAIL: launchd job holder was not stopped"; exit 1; }
! kill -0 "$HOLDER" 2>/dev/null && ! port_accepts "$HOLDER_PORT" || { echo "FAIL: launchd job holder still running"; exit 1; }
grep -qx "/bin/launchctl disable $JOB_TARGET" "$FIXTURE/launchctl" && grep -qx "/bin/launchctl bootout $JOB_TARGET" "$FIXTURE/launchctl" ||
    { echo "FAIL: the launchd job was not disabled and booted out"; cat "$FIXTURE/launchctl"; exit 1; }
[ "$(grep -n disable "$FIXTURE/launchctl" | cut -d: -f1)" -lt "$(grep -n bootout "$FIXTURE/launchctl" | cut -d: -f1)" ] ||
    { echo "FAIL: disable must come before bootout"; exit 1; }
[[ "$out" == *"To allow it again: sudo launchctl enable $JOB_TARGET"* ]] || { echo "FAIL: re-enable hint missing"; exit 1; }
echo "PASS: a launchd job holding the port is disabled, booted out, and stopped, with a re-enable hint"

listen com.apple.test-holder
reset_launchctl; JOB_TARGET="gui/$me/com.apple.test-holder" JOB_PID=$HOLDER
if stop_port_holders "$HOLDER_PORT" 2>/dev/null >/dev/null; then echo "FAIL: an Apple job was stopped"; exit 1; fi
kill -0 "$HOLDER" 2>/dev/null || { echo "FAIL: an Apple job's process was killed"; exit 1; }
! grep -qE 'disable|bootout' "$FIXTURE/launchctl" || { echo "FAIL: an Apple job was disabled"; exit 1; }
kill "$HOLDER"; LISTENER=""
echo "PASS: Apple's own jobs are never stopped"
unset -f run
run() { "$@"; }

# copy_files installs only the script; the installer never deploys a Clash Verge profile (dry run
# into a temporary folder, no root). The app alone maintains the profile.
(
    DIR="$FIXTURE/install" STATE_DIR="$FIXTURE/install/TailscaleVerge" SCRIPT="$FIXTURE/install/tailscale-verge.sh" INSTALL_OWNER=""
    copy_files || exit 1
    cmp -s "$SCRIPT" "$REPO/Sources/ExitIPDaemon/tailscale-verge.sh" && [ "$(stat -f %Lp "$SCRIPT")" = 755 ] || exit 1
    [ -z "$(find "$FIXTURE/install" -name '*.yaml')" ] || exit 1
) || { echo "FAIL: copy_files"; exit 1; }
! grep -qiE 'verge-profile|clash-verge-profile|proxies:' "$DAEMON" || { echo "FAIL: daemon.sh refers to a profile"; exit 1; }
echo "PASS: install copies only tailscale-verge.sh (0755); it never deploys a profile"

# The removal grant: exactly the commands `brew uninstall` needs, nothing that loads or starts a job.
line=$(grant_line someone)
expected="someone ALL=(root) NOPASSWD: /bin/launchctl bootout system/$LABEL, /bin/launchctl bootout system/$HTTP_LABEL, /bin/launchctl kickstart -k system/$LABEL, /bin/rm -f $PLIST, /bin/rm -f $HTTP_PLIST, /bin/rm -rf /Library/Application\\ Support/ExitIPMonitor, /bin/rm -f /etc/sudoers.d/exitipmonitor-tailscale-verge"
[ "$line" = "$expected" ] || { echo "FAIL: grant line"; echo "$line"; exit 1; }
[ "$(awk -F', ' '{ print NF }' <<< "${line#*NOPASSWD: }")" = 7 ] || { echo "FAIL: the grant must list seven commands"; exit 1; }
! grep -qE 'bootstrap|enable|load|\*' <<< "$line" || { echo "FAIL: the grant permits loading or wildcards"; exit 1; }
grant_line someone > "$FIXTURE/grant"
/usr/sbin/visudo -cf "$FIXTURE/grant" >/dev/null 2>&1 || { echo "FAIL: visudo rejects the grant"; exit 1; }
(
    GRANT="$FIXTURE/installed-grant" INSTALL_OWNER=""
    install_grant someone || exit 1
    [ "$(cat "$GRANT")" = "$(grant_line someone)" ] && [ "$(stat -f %Lp "$GRANT")" = 440 ] || exit 1
) || { echo "FAIL: install_grant"; exit 1; }
(
    GRANT="$FIXTURE/bad-grant" INSTALL_OWNER=""
    grant_line() { echo 'someone ALL=(root) NOPASSWD /bin/rm'; }   # missing colon: invalid sudoers
    install_grant someone 2>/dev/null && exit 1
    [ ! -e "$GRANT" ]
) || { echo "FAIL: an invalid grant was installed"; exit 1; }
echo "PASS: the grant lists exactly seven commands, passes visudo, is installed 0440, and an invalid one is refused"

# The grant and opt-out marker belong to SUDO_USER, else the console user; never root or junk.
me_name=$(id -un)
[ "$(SUDO_USER="$me_name" target_user)" = "$me_name" ] || { echo "FAIL: SUDO_USER not used"; exit 1; }
for bad in '../x' 'a b' 'x;rm' 'no-such-user-exitip'; do
    if SUDO_USER="$bad" target_user >/dev/null 2>&1; then echo "FAIL: accepted user '$bad'"; exit 1; fi
done
echo "PASS: the target user comes from SUDO_USER and junk or unknown names are refused"

# The opt-out marker is written and removed as the user (sudo -u), in the user's own home.
run() { echo "$*" >> "$FIXTURE/marker"; }
rm -f "$FIXTURE/marker"
home=$(user_home "$me_name")
set_opt_out "$me_name" on && set_opt_out "$me_name" off || { echo "FAIL: set_opt_out"; exit 1; }
printf -v want '%s\n' \
    "/usr/bin/sudo -n -u $me_name -- /bin/mkdir -p $home/Library/Application Support/ExitIPMonitor" \
    "/usr/bin/sudo -n -u $me_name -- /usr/bin/touch $home/Library/Application Support/ExitIPMonitor/tailscale-verge-off" \
    "/usr/bin/sudo -n -u $me_name -- /bin/rm -f $home/Library/Application Support/ExitIPMonitor/tailscale-verge-off"
[ "$(cat "$FIXTURE/marker")"$'\n' = "$want" ] || { echo "FAIL: marker commands"; cat "$FIXTURE/marker"; exit 1; }
if set_opt_out no-such-user-exitip on 2>/dev/null; then echo "FAIL: marker for an unknown user"; exit 1; fi
unset -f run
run() { "$@"; }
echo "PASS: the opt-out marker is created and removed as the user, in their home"

# Preflight: a missing Tailscale or Clash Verge Rev is reported, never fatal.
mkdir -p "$FIXTURE/apps/Tailscale.app/Contents/MacOS" "$FIXTURE/apps/Clash Verge.app"
printf '#!/bin/sh\n' > "$FIXTURE/apps/Tailscale.app/Contents/MacOS/Tailscale"; chmod +x "$FIXTURE/apps/Tailscale.app/Contents/MacOS/Tailscale"
for tailscale in yes no; do
    for verge in yes no; do
        TAILSCALE_APP="$FIXTURE/apps/Tailscale.app" CLASH_VERGE_APP="$FIXTURE/apps/Clash Verge.app"
        [ $tailscale = yes ] || TAILSCALE_APP="$FIXTURE/apps/Missing Tailscale.app"
        [ $verge = yes ] || CLASH_VERGE_APP="$FIXTURE/apps/Missing Clash Verge.app"
        TAILSCALE_CLI="$TAILSCALE_APP/Contents/MacOS/Tailscale"
        out=$(preflight_report) || { echo "FAIL: preflight failed ($tailscale/$verge)"; exit 1; }
        if [ $tailscale = yes ]; then [[ "$out" == *"Tailscale: installed."* ]]; else
            [[ "$out" == *"Tailscale: not installed (expected $TAILSCALE_APP). The provider serves Reject until Tailscale is installed and connected."* ]]; fi ||
            { echo "FAIL: Tailscale line ($tailscale/$verge): $out"; exit 1; }
        if [ $verge = yes ]; then [[ "$out" == *"Clash Verge Rev: installed."* ]]; else
            [[ "$out" == *"Clash Verge Rev: not installed (expected $CLASH_VERGE_APP). Nothing uses the provider until you install it and import the profile shown in Exit IP's dashboard."* ]]; fi ||
            { echo "FAIL: Clash Verge line ($tailscale/$verge): $out"; exit 1; }
    done
done
TAILSCALE_APP="/Applications/Tailscale.app" TAILSCALE_CLI="/Applications/Tailscale.app/Contents/MacOS/Tailscale" CLASH_VERGE_APP="/Applications/Clash Verge.app"
echo "PASS: the preflight reports each missing app in plain words and never fails"

# Installing and removing need root; status does not.
for action in install remove; do
    out=$(/bin/bash "$DAEMON" "$action" 2>&1); status=$?
    [ "$status" = 1 ] && [[ "$out" == *"run as root"* ]] || { echo "FAIL: $action without root: $status $out"; exit 1; }
done
echo "PASS: install and remove refuse to run without root"
/bin/bash "$DAEMON" status >/dev/null || { echo "FAIL: status"; exit 1; }
/bin/bash "$DAEMON" bogus >/dev/null 2>&1; [ $? = 2 ] || { echo "FAIL: usage exit status"; exit 1; }
echo "PASS: status works without root; an unknown action is a usage error"
