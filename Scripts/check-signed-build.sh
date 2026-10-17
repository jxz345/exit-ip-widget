#!/usr/bin/env bash
# Inspect a built app's signing, architectures, App Group entitlement, and embedded widget extension.
# This is read-only: it never changes signing settings or profiles.
#
#   bash Scripts/check-signed-build.sh [path/to/ExitIPMonitor.app]
set -u -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_PATH="${1:-$PROJECT_ROOT/XcodeProject/DerivedData/Build/Products/Debug/ExitIPMonitor.app}"

pass() { printf 'PASS  %s\n' "$1"; }
warn() { printf 'WARN  %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; }

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    sed -n '2,8p' "$0"
    exit 0
fi

if [[ "$(uname -s)" != "Darwin" ]]; then
    warn "Signing diagnostics are intended for macOS (current host: $(uname -s))."
    exit 0
fi

if [[ ! -d "$APP_PATH" ]]; then
    fail "App bundle not found: $APP_PATH"
    exit 2
fi

printf 'App: %s\n' "$APP_PATH"
if codesign --verify --deep --strict "$APP_PATH" >/dev/null 2>&1; then
    pass "Code signature verifies"
else
    warn "Code signature does not verify"
fi

signature_info="$(codesign -dvv "$APP_PATH" 2>&1 || true)"
if grep -q 'linker-signed' <<<"$signature_info" || grep -q 'Sealed Resources=none' <<<"$signature_info"; then
    fail "Only a linker signature (bundle not sealed): another Mac reports this app as damaged. Use Scripts/package-release.sh"
elif grep -q 'Signature=adhoc' <<<"$signature_info"; then
    pass "Ad-hoc signed, bundle sealed (install on another Mac with the .pkg or install.sh from package-release.sh)"
elif authority="$(grep -m1 '^Authority=' <<<"$signature_info")"; then
    pass "Signed by ${authority#Authority=}"
fi

app_binary="$APP_PATH/Contents/MacOS/ExitIPMonitor"
if archs="$(lipo -archs "$app_binary" 2>/dev/null)"; then
    if [[ " $archs " == *" arm64 "* && " $archs " == *" x86_64 "* ]]; then
        pass "Universal binary ($archs)"
    else
        warn "Binary architectures: $archs (not universal: Macs with another architecture cannot run it)"
    fi
fi

entitlements_file="$(mktemp -t exit-ip-entitlements).plist"
trap 'rm -f "$entitlements_file"' EXIT
if codesign -d --entitlements :- "$APP_PATH" >"$entitlements_file" 2>/dev/null && [[ -s "$entitlements_file" ]] && plutil -lint "$entitlements_file" >/dev/null 2>&1; then
    pass "Readable app entitlements"
    # plutil -extract treats dots as key-path separators, so read the array with PlistBuddy.
    app_groups="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.application-groups' "$entitlements_file" 2>/dev/null || true)"
    if [[ -z "$app_groups" ]]; then
        warn "App Group entitlement is missing (expected for ad-hoc builds: the widget cannot read app data)"
    elif grep -q 'group.com.example.exitipmonitor' <<<"$app_groups"; then
        warn "App Group entitlement still uses the source-kit placeholder"
    elif grep -q 'group\.' <<<"$app_groups"; then
        pass "App Group entitlement is present"
    else
        warn "App Group entitlement does not contain a registered group identifier"
    fi
else
    warn "No readable signed entitlements were found (expected for ad-hoc builds: the app runs unsandboxed)"
fi

widget_bundle="$APP_PATH/Contents/PlugIns/ExitIPMonitorWidgets.appex"
if [[ -d "$widget_bundle" ]]; then
    pass "Embedded widget extension is present"
    if codesign --verify --deep --strict "$widget_bundle" >/dev/null 2>&1; then
        pass "Embedded widget extension signature verifies"
    else
        warn "Embedded widget extension is unsigned or invalid"
    fi
else
    fail "Embedded widget extension is missing"
fi

printf '\nDiagnostics complete.\n'
