#!/bin/bash
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
source "$REPO/Sources/ExitIPDiagnostics/diagnose-launch.sh"
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
first_log=$(new_step_log "$fixture" install)
second_log=$(new_step_log "$fixture" install)
[ "$first_log" != "$second_log" ] && [ -f "$first_log" ] && [ -f "$second_log" ]
echo 'PASS: repeated installs get distinct log files on BSD mktemp'
for script in "$REPO"/Sources/ExitIPDiagnostics/*.sh "$REPO"/Scripts/install-release.sh "$REPO"/Scripts/package-release.sh; do
    /bin/bash -n "$script"
done

bounded_command 2 success /usr/bin/true >/dev/null 2>&1
if bounded_command 2 failure /bin/bash -c 'exit 7' >"$fixture/failure" 2>&1; then exit 1; else status=$?; fi
[ "$status" = 7 ] && grep -q 'status=7' "$fixture/failure"
started=$SECONDS
if bounded_command 1 stall /bin/bash -c 'sleep 60 & echo $! > "$1"; wait' _ "$fixture/child" >"$fixture/timeout" 2>&1; then exit 1; else status=$?; fi
[ "$status" = 124 ] && [ "$((SECONDS - started))" -lt 5 ]
child=$(cat "$fixture/child")
! /bin/kill -0 "$child" 2>/dev/null
grep -q 'timed out' "$fixture/timeout"
echo 'PASS: bounded commands preserve failure status and terminate a stalled command and its child'

app='/Applications/ExitIPMonitor.app'
record="$fixture/launch.json"
make_record() {
    cat > "$record" <<EOF
{"pid":12345,"launch_id":"test-launch","started":100,"updated":105,"ready":true,"stage":"app_ready","bundle_path":"$app","version":"1.0","build":"3"}
EOF
}
process_alive() { [ "$1" = 12345 ]; }
same_file() { [ "$1" = "$2" ]; }
process_path() { printf '%s/Contents/MacOS/ExitIPMonitor\n' "$app"; }
check() { heartbeat_matches "$record" "$app" 3 1.0 100 110; }
reject() { if check; then echo "FAIL: $1"; exit 1; fi; }
make_record; check
echo 'PASS: ready app with a fresh heartbeat, matching path, version, build, and live PID'
make_record; plutil -replace ready -bool NO "$record"; reject 'blocked before readiness'
make_record; plutil -replace updated -integer 101 "$record"; reject 'stale heartbeat'
make_record; plutil -replace started -integer 99 "$record"; reject 'previous launch'
make_record; plutil -replace updated -integer 111 "$record"; reject 'future heartbeat'
make_record; plutil -replace build -string 2 "$record"; reject 'old build'
make_record; plutil -replace version -string 0.9 "$record"; reject 'old version'
make_record; plutil -replace bundle_path -string /tmp/ExitIPMonitor.app "$record"; reject 'another bundle'
make_record; plutil -replace pid -integer 54321 "$record"; reject 'dead PID'
make_record; process_path() { echo /usr/bin/sleep; }; reject 'reused PID'
printf 'broken json' > "$record"; reject 'incomplete record'
echo 'PASS: startup stalls, stale/malformed records, old builds, wrong paths, and PID reuse cannot report success'

# A first launch may be translocated even when the app lives in /Applications.
translocated=/private/var/folders/test/T/AppTranslocation/test-id/d/ExitIPMonitor.app
make_record; plutil -replace bundle_path -string "$translocated" "$record"
process_path() { printf '%s/Contents/MacOS/ExitIPMonitor\n' "$translocated"; }
native_cdhash() { echo matching-code-hash; }
bounded_command() { return 0; }
check
native_cdhash() { if [ "$1" = "$app" ]; then echo expected; else echo wrong; fi; }
reject 'different translocated signature'
native_cdhash() { echo matching-code-hash; }
bounded_command() { return 1; }
reject 'invalid translocated signature'
echo 'PASS: translocation requires the same code identity and a valid sealed bundle'

# Exercise the real CLI: an invalid signature must fail before LaunchServices is invoked.
mkdir -p "$fixture/Unsigned.app/Contents"
cat > "$fixture/Unsigned.app/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict><key>CFBundleVersion</key><string>3</string><key>CFBundleShortVersionString</key><string>1.0</string></dict></plist>
EOF
if /bin/bash "$REPO/Sources/ExitIPDiagnostics/diagnose-launch.sh" --app "$fixture/Unsigned.app" --launch --timeout 1 --output "$fixture/signature-check" > "$fixture/cli-output" 2>&1; then
    echo 'FAIL: unsigned app reported success'; exit 1
fi
grep -q 'Invalid signature' "$fixture/cli-output"
! grep -q 'BEGIN.*open' "$fixture/cli-output"
echo 'PASS: invalid signature fails before the app is launched'

# Generated install.sh must be self-contained, and a checksum failure must not replace the app.
awk -v support="$REPO/Sources/ExitIPDiagnostics/command-support.sh" '
    /^# @COMMAND_SUPPORT@$/ { while ((getline line < support) > 0) print line; close(support); next }
    { print }
' "$REPO/Scripts/install-release.sh" | sed -e 's|@RELEASE_REPO@|test/repo|' -e 's|@VERSION@|1.0|' \
    -e 's|@PKG_SHA256@|0000000000000000000000000000000000000000000000000000000000000000|' > "$fixture/install.sh"
mkdir -p "$fixture/Applications/ExitIPMonitor.app"
touch "$fixture/Applications/ExitIPMonitor.app/preserve"
echo invalid > "$fixture/wrong.pkg"
if EXIT_IP_LOG_DIRECTORY="$fixture/logs" EXIT_IP_INSTALL_DIR="$fixture/Applications" \
    /bin/bash "$fixture/install.sh" "$fixture/wrong.pkg" > "$fixture/install-output" 2>&1; then
    echo 'FAIL: checksum mismatch reported success'; exit 1
fi
[ -f "$fixture/Applications/ExitIPMonitor.app/preserve" ]
grep -q 'does not match release' "$fixture/install-output"
echo 'PASS: generated installer rejects checksum mismatch before replacing the installed app'
echo 'All installation tests passed.'
