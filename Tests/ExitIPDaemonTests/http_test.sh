#!/bin/bash
# Exercises tailscale-verge.sh's HTTP responder against fixture state files. Expected bytes are
# the reference provider's (Python http.server) responses, captured from the running agent on
# 2026-10-18, with only the Date header normalized. One deliberate difference: /provider.yaml is
# sent as text/plain (the reference used application/yaml), so a browser shows it instead of
# downloading it. Mihomo's HTTP provider reads only the status code, ETag, and body.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/../.." && pwd)
SCRIPT="$REPO/Sources/ExitIPDaemon/tailscale-verge.sh"
[ "$(id -u)" != 0 ] || { echo "Run as a normal user." >&2; exit 1; }
FIXTURE=$(mktemp -d)
trap '/bin/rm -rf "$FIXTURE"' EXIT
export EXITIP_TSV_TEST=1 EXITIP_TSV_STATE_DIR="$FIXTURE" EXITIP_TSV_NOW=2000000000 EXITIP_TSV_READ_TIMEOUT=1

DIRECT=$'proxies:\n  - name: TS-NATIVE\n    type: direct\n    interface-name: utun7\n    udp: true\n'
REJECT=$'proxies:\n  - name: TS-NATIVE\n    type: reject\n'

# state STATE INTERFACE REASON CHECKED [PROVIDER_BYTES]
state() {
    printf 'state=%s\ninterface=%s\nreason=%s\nchecked=%s\nuid=501\n' "$1" "$2" "$3" "$4" > "$FIXTURE/state"
    printf '%s' "${5:-$REJECT}" > "$FIXTURE/provider.yaml"
}

# request RAW_REQUEST → the response with its Date header replaced by DATE
request() {
    printf '%b' "$1" | /bin/bash "$SCRIPT" http | /usr/bin/sed -E $'s/^Date: [A-Z][a-z]{2}, [0-9]{2} [A-Z][a-z]{2} [0-9]{4} [0-9]{2}:[0-9]{2}:[0-9]{2} GMT\r$/Date: DATE\r/'
    printf x
}

# expected_response STATUS TYPE BODY [HEAD_ONLY] → EXPECTED (printf -v keeps every trailing byte)
expected_response() {
    printf -v EXPECTED 'HTTP/1.1 %s\r\nServer: tailscale-verge-live-v1 \r\nDate: DATE\r\nContent-Type: %s\r\nContent-Length: %s\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nConnection: close\r\n\r\n' "$1" "$2" "${#3}"
    [ "${4:-0}" = 1 ] || EXPECTED+="$3"
    EXPECTED+=x
}

expect() { # NAME GOT EXPECTED
    [ "$2" = "$3" ] || { echo "FAIL: $1"; printf -- '--- got\n%s\n--- expected\n%s\n' "$2" "$3"; exit 1; }
    echo "PASS: $1"
}

check() { # NAME REQUEST STATUS TYPE BODY [HEAD_ONLY]
    expected_response "$3" "$4" "$5" "${6:-0}"
    expect "$1" "$(request "$2")" "$EXPECTED"
}

status_body() { # AGE INTERFACE_JSON REASON STATE
    printf '{"checked_age_seconds": %s, "identity": "tailscale-verge-live-v1", "interface": %s, "reason": "%s", "state": "%s"}\n' "$@"
}

GET_PROVIDER='GET /provider.yaml HTTP/1.1\r\nHost: 127.0.0.1:18766\r\nAccept: */*\r\n\r\n'
GET_STATUS='GET /status.json HTTP/1.1\r\nHost: 127.0.0.1:18766\r\n\r\n'
NOT_FOUND=$'Not found\n'
YAML_TYPE='text/plain; charset=utf-8'

# The captured reference responses had Content-Length 86 (Direct) and 46 (Reject); the bodies
# Mihomo parses must stay exactly these bytes.
[ "${#DIRECT}" = 86 ] && [ "${#REJECT}" = 46 ] || { echo "FAIL: provider byte lengths"; exit 1; }

state direct utun7 verified 1999999999 "$DIRECT"
check "fresh Direct: exact provider bytes" "$GET_PROVIDER" "200 OK" "$YAML_TYPE" "$DIRECT"
check "fresh Direct: status.json" "$GET_STATUS" "200 OK" application/json "$(status_body 1.0 '"utun7"' verified direct)"$'\n'
check "HEAD sends the headers only" 'HEAD /provider.yaml HTTP/1.1\r\n\r\n' "200 OK" "$YAML_TYPE" "$DIRECT" 1
check "HTTP/1.0 request is answered" 'GET /provider.yaml HTTP/1.0\r\n\r\n' "200 OK" "$YAML_TYPE" "$DIRECT"
check "unknown path: 404" 'GET /other HTTP/1.1\r\n\r\n' "404 Not Found" text/plain "$NOT_FOUND"
check "query string is not the provider path" 'GET /provider.yaml?x=1 HTTP/1.1\r\n\r\n' "404 Not Found" text/plain "$NOT_FOUND"
check "HEAD of an unknown path: 404 headers" 'HEAD /other HTTP/1.1\r\n\r\n' "404 Not Found" text/plain "$NOT_FOUND" 1

ERROR_501=$'<!DOCTYPE HTML>\n<html lang="en">\n    <head>\n        <meta charset="utf-8">\n        <style type="text/css">\n            :root {\n                color-scheme: light dark;\n            }\n        </style>\n        <title>Error response</title>\n    </head>\n    <body>\n        <h1>Error response</h1>\n        <p>Error code: 501</p>\n        <p>Message: Unsupported method (\'POST\').</p>\n        <p>Error code explanation: 501 - Server does not support this operation.</p>\n    </body>\n</html>\n'
expect "POST: the reference server's 501 page" "$(request 'POST /provider.yaml HTTP/1.1\r\nContent-Length: 0\r\n\r\n')" \
    "HTTP/1.1 501 Unsupported method ('POST')"$'\r\n'"Server: tailscale-verge-live-v1 "$'\r\n'"Date: DATE"$'\r\n'"Connection: close"$'\r\n'"Content-Type: text/html;charset=utf-8"$'\r\n'"Content-Length: 482"$'\r\n\r\n'"${ERROR_501}x"
case "$(request 'GARBAGE\r\n\r\n')" in "HTTP/1.1 400 Bad request"$'\r\n'*) echo "PASS: malformed request: 400" ;; *) echo "FAIL: malformed request"; exit 1 ;; esac
flood='GET /provider.yaml HTTP/1.1\r\n'
for _ in $(seq 1 101); do flood+='X-Pad: 1\r\n'; done
case "$(request "$flood\r\n")" in "HTTP/1.1 400 Bad request"$'\r\n'*) echo "PASS: more than 100 headers: 400" ;; *) echo "FAIL: header flood"; exit 1 ;; esac
[ "$(request '')" = x ] || { echo "FAIL: an empty connection got a response"; exit 1; }
echo "PASS: an empty connection closes without a response"
# Keep the client's write end open, but wait only for the responder. Timing a pipeline with a
# sleeping writer measures the writer's sleep instead; integer wall-clock seconds also round
# that sleep up unpredictably. A monotonic deadline catches a missing read timeout without
# requiring EOF or a late write (which would otherwise produce a misleading broken pipe).
/usr/bin/python3 - "$SCRIPT" <<'PY'
import subprocess
import sys
import time

for name, prefix in (
    ("request line", b""),
    ("partial request line", b"GET /provider.yaml HTTP/1.1"),
    ("headers", b"GET /provider.yaml HTTP/1.1\r\n"),
):
    started = time.monotonic()
    with subprocess.Popen(
        ["/bin/bash", sys.argv[1], "http"],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    ) as responder:
        try:
            if prefix:
                responder.stdin.write(prefix)
                responder.stdin.flush()
            responder.wait(timeout=3)
            elapsed = time.monotonic() - started
            output = responder.stdout.read()
            assert responder.returncode == 0, "responder exited with %s" % responder.returncode
            assert output == b"", "stalled client got a response: %r" % output
            assert elapsed >= 0.75, "responder closed before its one-second read timeout"
        except subprocess.TimeoutExpired:
            raise SystemExit("FAIL: stalled %s held the responder beyond 3 seconds" % name)
        finally:
            if responder.poll() is None:
                responder.kill()
                responder.wait()
    print("PASS: stalled %s dropped after %.3f seconds with the client still connected" % (name, elapsed))
PY
for incomplete in 'GET /provider.yaml HTTP/1.1' 'GET /provider.yaml HTTP/1.1\r\nHost: localhost'; do
    [ "$(request "$incomplete")" = x ] || { echo "FAIL: incomplete request at EOF got a response"; exit 1; }
done
echo "PASS: incomplete requests at EOF close without a response"

# Reject states and the freshness guard (provider.py ProviderState.snapshot).
state reject "" no-tailscale-route 1999999998
check "Reject state: reject bytes" "$GET_PROVIDER" "200 OK" "$YAML_TYPE" "$REJECT"
check "Reject state: status.json" "$GET_STATUS" "200 OK" application/json "$(status_body 2.0 null no-tailscale-route reject)"$'\n'
state direct utun7 verified 1999999988 "$DIRECT"
check "12 s old: still fresh" "$GET_PROVIDER" "200 OK" "$YAML_TYPE" "$DIRECT"
state direct utun7 verified 1999999987 "$DIRECT"
check "13 s old: monitor-stale → reject bytes" "$GET_PROVIDER" "200 OK" "$YAML_TYPE" "$REJECT"
check "13 s old: status.json says monitor-stale" "$GET_STATUS" "200 OK" application/json "$(status_body 13.0 null monitor-stale reject)"$'\n'
state direct utun7 verified 2000000002 "$DIRECT"
check "checked up to 2 s ahead: fresh, age 0" "$GET_STATUS" "200 OK" application/json "$(status_body 0.0 '"utun7"' verified direct)"$'\n'
state direct utun7 verified 2000000060 "$DIRECT"
check "checked far in the future: monitor-stale" "$GET_STATUS" "200 OK" application/json "$(status_body null null monitor-stale reject)"$'\n'
state direct en0 verified 1999999999 "$DIRECT"
check "a non-utun interface is never served" "$GET_PROVIDER" "200 OK" "$YAML_TYPE" "$REJECT"
check "a non-utun interface: invalid-interface" "$GET_STATUS" "200 OK" application/json "$(status_body 1.0 null invalid-interface reject)"$'\n'
state direct utun7 verified 1999999999 "${DIRECT//utun7/utun8}"
check "provider.yaml that disagrees with state: reject bytes" "$GET_PROVIDER" "200 OK" "$YAML_TYPE" "$REJECT"
printf 'state=direct\ninterface=utun7\nreason=verified\nchecked=soon\n' > "$FIXTURE/state"
check "malformed state: monitor-error" "$GET_STATUS" "200 OK" application/json "$(status_body null null monitor-error reject)"$'\n'
printf 'state=direct\ninterface=utun7\nreason=verified\nchecked=01999999999\n' > "$FIXTURE/state"
check "leading-zero checked time: monitor-error" "$GET_STATUS" "200 OK" application/json "$(status_body null null monitor-error reject)"$'\n'
rm -f "$FIXTURE/state" "$FIXTURE/provider.yaml"
check "no state yet: starting, reject bytes" "$GET_PROVIDER" "200 OK" "$YAML_TYPE" "$REJECT"
check "no state yet: status.json" "$GET_STATUS" "200 OK" application/json "$(status_body null null starting reject)"$'\n'
ln -s /etc/hosts "$FIXTURE/state"
check "a symlinked state file is ignored" "$GET_STATUS" "200 OK" application/json "$(status_body null null starting reject)"$'\n'
rm -f "$FIXTURE/state"

# HTTP never waits for discovery: the responder reads files only, even while a check hangs.
state direct utun7 verified 1999999999 "$DIRECT"
printf '#!/bin/bash\nexec /bin/sleep 30\n' > "$FIXTURE/hung"; chmod +x "$FIXTURE/hung"
EXITIP_TSV_ROUTE="$FIXTURE/hung" EXITIP_TSV_TIMEOUT=30 EXITIP_TSV_LOGGER=/usr/bin/true EXITIP_TSV_STATE_DIR="$FIXTURE/monitor" \
    /bin/bash "$SCRIPT" monitor &
monitor=$!
sleep 0.5
start=$(perl -MTime::HiRes=time -e 'printf "%d", time * 1000')
got=$(request "$GET_PROVIDER")
elapsed=$(( $(perl -MTime::HiRes=time -e 'printf "%d", time * 1000') - start ))
kill -TERM "$monitor" 2>/dev/null; wait "$monitor" 2>/dev/null || true
pkill -f "$FIXTURE/hung" 2>/dev/null || true
expected_response "200 OK" "$YAML_TYPE" "$DIRECT"
expect "served while a check hangs" "$got" "$EXPECTED"
[ "$elapsed" -lt 1000 ] || { echo "FAIL: response took ${elapsed} ms"; exit 1; }
echo "PASS: the response took ${elapsed} ms (under 1 s)"

# The responder never runs a discovery command; it only reads the two files.
if /usr/bin/awk '/^http_main\(\)/,/^}/' "$SCRIPT" | grep -E '\$\((ROUTE|IFCONFIG|SUDO|TAILSCALE_CLI)|"\$(ROUTE|IFCONFIG|SUDO|TAILSCALE_CLI)"' >/dev/null; then
    echo "FAIL: http_main runs a discovery command"; exit 1
fi
echo "PASS: http_main runs no discovery command"
