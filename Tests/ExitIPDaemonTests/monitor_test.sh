#!/bin/bash
# Exercises tailscale-verge.sh's monitor (discovery, files, loop) with stubbed route, ifconfig,
# sudo, and Tailscale CLI. Ports the reference provider's discovery tests (test_live.py).
# The test hooks are honored only for an ordinary user, so nothing here touches the Mac.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/../.." && pwd)
SCRIPT="$REPO/Sources/ExitIPDaemon/tailscale-verge.sh"
[ "$(id -u)" != 0 ] || { echo "Run as a normal user." >&2; exit 1; }
FIXTURE=$(mktemp -d)
trap '/bin/rm -rf "$FIXTURE"' EXIT
mkdir -p "$FIXTURE/state"

# Each stub prints its fixture file, fails when fail-<name> exists, and hangs when hang-<name> does.
stub() {
    local name=$1
    cat > "$FIXTURE/$name" <<STUB
#!/bin/bash
echo "\$*" >> "$FIXTURE/calls-$name"
[ ! -e "$FIXTURE/hang-$name" ] || exec /bin/sleep 30
[ ! -e "$FIXTURE/fail-$name" ] || exit 1
STUB
    chmod +x "$FIXTURE/$name"
}
stub route; stub ifconfig; stub cli
cat >> "$FIXTURE/route" <<STUB
n=\$(wc -l < "$FIXTURE/calls-route")
if [ "\$n" -gt 1 ] && [ -e "$FIXTURE/route2.txt" ]; then cat "$FIXTURE/route2.txt"; else cat "$FIXTURE/route1.txt"; fi
STUB
echo "cat \"$FIXTURE/ifconfig.txt\"" >> "$FIXTURE/ifconfig"
echo "cat \"$FIXTURE/ip.txt\"" >> "$FIXTURE/cli"
# sudo stub: requires the exact privilege-drop arguments, then runs the rest as this user.
cat > "$FIXTURE/sudo" <<STUB
#!/bin/bash
echo "\$*" > "$FIXTURE/sudo-args"
[ "\$1" = -n ] && [ "\$2" = -u ] && [ "\$3" = "#501" ] && [ "\$4" = -- ] && [ "\$5" = /usr/bin/env ] && [ "\$6" = -i ] || exit 99
shift 4
exec "\$@"
STUB
chmod +x "$FIXTURE/sudo"
printf '#!/bin/bash\necho "$*" >> "%s/log"\n' "$FIXTURE" > "$FIXTURE/logger"
chmod +x "$FIXTURE/logger"
# The first exec of a new executable can be delayed by macOS's scan of it; warm every stub up so
# the 1-second command bound below measures only the stubs' behavior.
for warm in route ifconfig cli logger; do "$FIXTURE/$warm" > /dev/null 2>&1 || true; done
"$FIXTURE/sudo" -n -u "#501" -- /usr/bin/env -i /usr/bin/true || true
rm -f "$FIXTURE"/calls-* "$FIXTURE/log"

export EXITIP_TSV_TEST=1 EXITIP_TSV_ROUTE="$FIXTURE/route" EXITIP_TSV_IFCONFIG="$FIXTURE/ifconfig"
export EXITIP_TSV_SUDO="$FIXTURE/sudo" EXITIP_TSV_CLI="$FIXTURE/cli" EXITIP_TSV_LOGGER="$FIXTURE/logger"
export EXITIP_TSV_STATE_DIR="$FIXTURE/state" EXITIP_TSV_TIMEOUT=1 EXITIP_TSV_CONSOLE="501 jay /Users/jay"

ROUTE_OK='   route to: 100.100.100.100
destination: 100.100.100.100
  interface: utun7
      flags: <UP,HOST,DONE,WASCLONED,IFSCOPE,IFREF>'
ROUTE_DEFAULT='   route to: 100.100.100.100
destination: default
       mask: default
    gateway: 192.168.10.1
  interface: en0'
ROUTE_PHYS=${ROUTE_OK//utun7/en0}
ROUTE_UTUN0=${ROUTE_OK//utun7/utun0}
IFC_OK=$'utun7: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 1280\n\tinet 100.123.84.71 --> 100.123.84.71 netmask 0xffffffff'
IFC_DOWN=${IFC_OK//<UP,/<}
IFC_MIHOMO=$'utun7: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 9000\n\tinet 198.18.0.1 --> 198.18.0.1 netmask 0xfffffffc'

# setup [route=…] [route2=…] [ip=…] [ifc=…] [fail=name] [hang=name]
setup() {
    rm -f "$FIXTURE"/calls-* "$FIXTURE"/fail-* "$FIXTURE"/hang-* "$FIXTURE/route2.txt" "$FIXTURE/sudo-args"
    printf '%s\n' "$ROUTE_OK" > "$FIXTURE/route1.txt"
    printf '100.123.84.71\n' > "$FIXTURE/ip.txt"
    printf '%s\n' "$IFC_OK" > "$FIXTURE/ifconfig.txt"
    local arg
    for arg in "$@"; do
        case "$arg" in
            route=*) printf '%s\n' "${arg#route=}" > "$FIXTURE/route1.txt" ;;
            route2=*) printf '%s\n' "${arg#route2=}" > "$FIXTURE/route2.txt" ;;
            ip=*) printf '%s' "${arg#ip=}" > "$FIXTURE/ip.txt" ;;
            ifc=*) printf '%s\n' "${arg#ifc=}" > "$FIXTURE/ifconfig.txt" ;;
            fail=*) touch "$FIXTURE/fail-${arg#fail=}" ;;
            hang=*) touch "$FIXTURE/hang-${arg#hang=}" ;;
        esac
    done
}

discover_result() {
    /bin/bash -c 'source "$1"; WORK=$(mktemp -d); OUT=$WORK/out; discover; echo "${IFACE:-none} $REASON"; rm -rf "$WORK"' _ "$SCRIPT"
}

# check NAME EXPECTED_INTERFACE EXPECTED_REASON [setup args…]
check() {
    local name=$1 expected="$2 $3" got
    shift 3
    setup "$@"
    got=$(discover_result)
    [ "$got" = "$expected" ] || { echo "FAIL: $name: got '$got', expected '$expected'"; exit 1; }
    echo "PASS: $name"
}

check "verified" utun7 verified
check "default route rejected" none no-tailscale-route "route=$ROUTE_DEFAULT"
check "physical route rejected" none no-tailscale-route "route=$ROUTE_PHYS"
check "non-CGNAT address rejected" none no-tailscale-ip $'ip=192.168.1.2\n'
check "empty CLI output rejected" none no-tailscale-ip "ip="
check "two addresses rejected" none no-tailscale-ip $'ip=100.1.2.3\n100.4.5.6\n'
check "leading-zero address rejected" none no-tailscale-ip $'ip=100.064.1.2\n'
check "address outside 100.64.0.0/10 rejected" none no-tailscale-ip $'ip=100.128.0.1\n'
check "interface down" none interface-not-owned-by-tailscale "ifc=$IFC_DOWN"
check "interface owned by another tunnel (Mihomo)" none interface-not-owned-by-tailscale "ifc=$IFC_MIHOMO"
check "route changed during check" none route-changed-during-check "route2=$ROUTE_UTUN0"
check "CLI unavailable" none tailscale-cli-unavailable fail=cli
check "CLI timeout" none tailscale-cli-timeout hang=cli
check "route timeout" none route-timeout hang=route
check "ifconfig unavailable" none interface-unavailable fail=ifconfig
EXITIP_TSV_CLI=/nonexistent/Tailscale check "Tailscale not installed: reject with a clear reason" none tailscale-not-installed
[ ! -s "$FIXTURE/calls-route" ] && [ ! -e "$FIXTURE/sudo-args" ] || { echo "FAIL: commands ran without Tailscale installed"; exit 1; }
echo "PASS: without Tailscale nothing else runs (no route, sudo, or ifconfig)"
EXITIP_TSV_CONSOLE="0 root /var/root" check "nobody at the console (login window): reject" none no-console-user
EXITIP_TSV_CONSOLE="200 _daemon /var/empty" check "system account at the console: reject" none no-console-user

# Only the CLI drops privileges, with a clean environment and the fixed arguments.
setup
discover_result > /dev/null
args=$(cat "$FIXTURE/sudo-args")
[[ "$args" == "-n -u #501 -- /usr/bin/env -i HOME=/Users/jay USER=jay LOGNAME=jay PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C TAILSCALE_BE_CLI=1 $FIXTURE/cli ip -4" ]] ||
    { echo "FAIL: CLI arguments: $args"; exit 1; }
[ "$(cat "$FIXTURE/calls-route")" = $'-n get 100.100.100.100\n-n get 100.100.100.100' ] || { echo "FAIL: route arguments"; exit 1; }
[ "$(cat "$FIXTURE/calls-ifconfig")" = utun7 ] || { echo "FAIL: ifconfig arguments"; exit 1; }
echo "PASS: only the CLI runs through sudo -u #501 with a clean environment"

# write_state: provider.yaml holds the exact served bytes; it is rewritten only when they change.
state_pass() { # IFACE REASON EPOCH
    /bin/bash -c 'source "$1"; IFACE=$2 REASON=$3 USED_UID=501; write_state "$4"' _ "$SCRIPT" "$@"
}
state_pass utun7 verified 1000
expected=$'proxies:\n  - name: TS-NATIVE\n    type: direct\n    interface-name: utun7\n    udp: true\n'
[ "$(cat "$FIXTURE/state/provider.yaml"; printf x)" = "${expected}x" ] || { echo "FAIL: direct provider.yaml bytes"; exit 1; }
[ "$(cat "$FIXTURE/state/state")" = $'state=direct\ninterface=utun7\nreason=verified\nchecked=1000\nuid=501' ] ||
    { echo "FAIL: state file"; exit 1; }
inode=$(stat -f %i "$FIXTURE/state/provider.yaml")
state_pass utun7 verified 1002
[ "$(stat -f %i "$FIXTURE/state/provider.yaml")" = "$inode" ] || { echo "FAIL: unchanged provider.yaml was rewritten"; exit 1; }
grep -q '^checked=1002$' "$FIXTURE/state/state" || { echo "FAIL: state not refreshed"; exit 1; }
state_pass "" no-tailscale-route 1004
[ "$(cat "$FIXTURE/state/provider.yaml"; printf x)" = $'proxies:\n  - name: TS-NATIVE\n    type: reject\nx' ] ||
    { echo "FAIL: reject provider.yaml bytes"; exit 1; }
[ -z "$(find "$FIXTURE/state" -name '.*' -type f)" ] || { echo "FAIL: temporary files left behind"; exit 1; }
echo "PASS: provider.yaml holds the exact provider bytes and changes only with them"

# The loop: writes files every pass, logs only state changes, and exits on TERM.
setup
rm -f "$FIXTURE/state/"* "$FIXTURE/log"
EXITIP_TSV_POLL=0.2 /bin/bash "$SCRIPT" monitor &
loop=$!
for _ in $(seq 1 50); do [ -s "$FIXTURE/state/state" ] && break; sleep 0.1; done
sleep 1
kill -TERM "$loop"; wait "$loop" || true
grep -q '^state=direct$' "$FIXTURE/state/state" || { echo "FAIL: loop did not write state"; exit 1; }
[ "$(wc -l < "$FIXTURE/log" | tr -d ' ')" = 1 ] || { echo "FAIL: loop logged $(wc -l < "$FIXTURE/log") lines, expected one change"; exit 1; }
grep -q 'state=direct interface=utun7 reason=verified uid=501' "$FIXTURE/log" || { echo "FAIL: log line"; exit 1; }
[ "$(wc -l < "$FIXTURE/calls-route" | tr -d ' ')" -gt 2 ] || { echo "FAIL: loop ran only once"; exit 1; }
echo "PASS: the loop refreshes every pass, logs only changes, and stops on TERM"

# Hooks are ignored under launchd: root (monitor) and nobody (responder) never read them.
grep -q 'if \[ "${EXITIP_TSV_TEST:-}" = 1 \] && \[ "$(/usr/bin/id -u)" != 0 \] && \[ "$(/usr/bin/id -un)" != nobody \]; then' "$SCRIPT"
echo "PASS: test hooks are disabled for root and nobody"
