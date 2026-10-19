#!/bin/bash
# Real packaging/extraction into a temporary directory, with cleanup and launch substitutes.
# No real app process, service, /Applications entry or privileged command is touched.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
app="$fixture/root/ExitIPMonitor.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$fixture/Applications/ExitIPMonitor.app"
cp /usr/bin/true "$app/Contents/MacOS/ExitIPMonitor"
cat > "$app/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>test.exitip.reinstall</string>
<key>CFBundleExecutable</key><string>ExitIPMonitor</string>
<key>CFBundleVersion</key><string>7</string>
</dict></plist>
EOF
cat > "$app/Contents/Resources/cleanup-installation.sh" <<'EOF'
#!/bin/bash
[ "$1" = --app ] || exit 2
[ -f "$2/preserve" ] || exit 3
echo cleanup >> "$TEST_ORDER"
[ "${TEST_CLEANUP_FAIL:-0}" = 0 ] || exit 1
EOF
cat > "$app/Contents/Resources/diagnose-launch.sh" <<'EOF'
#!/bin/bash
echo launch >> "$TEST_ORDER"
[ ! -e "$2/preserve" ] && [ -f "$2/Contents/MacOS/ExitIPMonitor" ]
EOF
codesign --force --sign - --timestamp=none "$app" > "$fixture/sign" 2>&1
pkgbuild --root "$fixture/root" --identifier test.exitip.reinstall --version 1.0 \
    "$fixture/ExitIPMonitor-1.0.pkg" > "$fixture/package" 2>&1
sha=$(shasum -a 256 "$fixture/ExitIPMonitor-1.0.pkg" | awk '{print $1}')
awk -v support="$REPO/Sources/ExitIPDiagnostics/command-support.sh" '
    /^# @COMMAND_SUPPORT@$/ { while ((getline line < support) > 0) print line; close(support); next }
    { print }
' "$REPO/Scripts/install-release.sh" | sed -e 's|@RELEASE_REPO@|test/repo|' -e 's|@VERSION@|1.0|' \
    -e "s|@PKG_SHA256@|$sha|" > "$fixture/install.sh"
export EXIT_IP_LOG_DIRECTORY="$fixture/logs" EXIT_IP_INSTALL_DIR="$fixture/Applications" TEST_ORDER="$fixture/order"
touch "$fixture/Applications/ExitIPMonitor.app/preserve"
if TEST_CLEANUP_FAIL=1 /bin/bash "$fixture/install.sh" "$fixture/ExitIPMonitor-1.0.pkg" > "$fixture/fail" 2>&1; then
    echo 'FAIL: installer ignored cleanup failure'; exit 1
fi
[ -f "$fixture/Applications/ExitIPMonitor.app/preserve" ]
[ "$(cat "$TEST_ORDER")" = cleanup ]
echo 'PASS: cleanup failure preserves the installed app and prevents launch'
: > "$TEST_ORDER"
/bin/bash "$fixture/install.sh" "$fixture/ExitIPMonitor-1.0.pkg" > "$fixture/success" 2>&1 || { cat "$fixture/success"; exit 1; }
[ "$(cat "$TEST_ORDER")" = "$(printf 'cleanup\nlaunch')" ]
echo 'PASS: verified package cleans before replacement, then launches the app without provider setup'

mkdir "$fixture/scripts"
cp "$REPO/Scripts/pkg/preinstall" "$fixture/scripts/"
cat > "$fixture/scripts/cleanup-installation.sh" <<'EOF'
#!/bin/bash
printf '%s\n' "$@" > "$TEST_ORDER"
exit 17
EOF
status=0
/bin/bash "$fixture/scripts/preinstall" unused "$fixture/Applications" / || status=$?
[ "$status" = 17 ]
[ "$(cat "$TEST_ORDER")" = "$(printf '%s\n%s' --app "$fixture/Applications/ExitIPMonitor.app")" ]
echo 'PASS: package preinstall uses its packaged helper and propagates cleanup failure'
