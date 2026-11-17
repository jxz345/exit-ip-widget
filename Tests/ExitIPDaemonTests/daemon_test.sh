#!/bin/bash
# Installer contract checks only; launchctl is mocked and no installed files are touched.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/../.." && pwd)
source "$REPO/Sources/ExitIPDaemon/daemon.sh"
fixture=$(mktemp -d)
trap '/bin/rm -rf "$fixture"' EXIT
service_plist > "$fixture/service.plist"
/usr/bin/plutil -lint "$fixture/service.plist" >/dev/null
[ "$(/usr/bin/plutil -extract ProgramArguments.0 raw -o - "$fixture/service.plist")" = "$EXECUTABLE" ]
[ "$(/usr/bin/plutil -extract RunAtLoad raw -o - "$fixture/service.plist")" = true ]
[ "$(/usr/bin/plutil -extract KeepAlive raw -o - "$fixture/service.plist")" = true ]
/usr/bin/python3 - "$fixture/service.plist" <<'PY'
import plistlib, sys
p = plistlib.load(open(sys.argv[1], 'rb'))
assert p['MachServices'] == {'com.example.exitipmonitor.daemon': True}
assert 'UserName' not in p and 'LimitLoadToSessionType' not in p
assert len(p['ProgramArguments']) == 1
PY
echo 'PASS: one system LaunchDaemon starts at boot, restarts, and exposes one Mach service'

run() {
    local count
    echo "$*" >> "$fixture/commands"
    if [ "$2" = bootout ]; then return 0; fi
    count=$(cat "$fixture/reads" 2>/dev/null || echo 0)
    echo "$((count + 1))" > "$fixture/reads"
    if [ "$count" -lt 3 ]; then return 0; fi
    echo "Could not find service \"$LABEL\" in domain for system"
    return 113
}
unload "$LABEL"
[ "$(cat "$fixture/reads")" = 4 ]
grep -q "bootout system/$LABEL" "$fixture/commands"
echo 'PASS: uninstall waits for launchd to confirm service removal'
run() { return 124; }
if unload "$LABEL" > /dev/null 2>&1; then echo 'FAIL: inspection timeout treated as absence'; exit 1; fi
run() { echo 'permission denied'; return 1; }
if unload "$LABEL" > /dev/null 2>&1; then echo 'FAIL: permission error treated as absence'; exit 1; fi
echo 'PASS: inspection failures cannot report successful removal'

ln -s "$fixture" "$fixture/link"
if secure_directory "$fixture/link" > /dev/null 2>&1; then echo 'FAIL: symlink accepted'; exit 1; fi
if [ "$(id -u)" != 0 ]; then
    if install_service > /dev/null 2>&1; then echo 'FAIL: unprivileged install accepted'; exit 1; fi
    if uninstall_service > /dev/null 2>&1; then echo 'FAIL: unprivileged removal accepted'; exit 1; fi
fi
echo 'PASS: installation requires administrator privileges and rejects symlinked executable directories'

# A failed replacement restores bytes and restarts only previously loaded services.
(
    stage="$fixture/rollback"; mkdir -p "$stage/backup"
    EXECUTABLE="$fixture/executable"; PLIST="$fixture/launch.plist"
    installed_files=("$EXECUTABLE" "$PLIST" "$fixture/new-file")
    echo old-binary > "$stage/backup/executable"
    echo old-plist > "$stage/backup/launch.plist"
    echo replacement > "$EXECUTABLE"; echo replacement > "$PLIST"; touch "$fixture/new-file"
    old_loaded=1 legacy_loaded=0 legacy_http_loaded=0
    unload() { echo "unload $1" >> "$fixture/rollback-commands"; }
    run() { echo "$*" >> "$fixture/rollback-commands"; }
    restore_installation
    [ "$(cat "$EXECUTABLE")" = old-binary ] && [ "$(cat "$PLIST")" = old-plist ]
    [ ! -e "$fixture/new-file" ]
    grep -q "bootstrap system $PLIST" "$fixture/rollback-commands"
    [ "$(wc -l < "$fixture/rollback-commands" | tr -d ' ')" = 2 ]
)
echo 'PASS: a failed upgrade restores the old binary/plist, removes new files and restarts the prior service'
