#!/usr/bin/env bash
# Exit IP Monitor build-environment preflight
# Usage: bash Scripts/check-build-environment.sh [--project /path/to/exit_ip_widget] [--test]
# This script only inspects the environment. It never installs software or changes signing settings.

set -u -o pipefail

MINIMUM_SDK_MAJOR=26
blocking_failures=0
warnings=0
run_tests=0
project_override=""
project_available=0
full_xcode_active=0

pass() {
    printf 'PASS  %s\n' "$1"
}

warn() {
    printf 'WARN  %s\n' "$1"
    warnings=$((warnings + 1))
}

fail() {
    printf 'FAIL  %s\n' "$1"
    blocking_failures=$((blocking_failures + 1))
}

section() {
    printf '\n== %s ==\n' "$1"
}

usage() {
    cat <<'EOF'
Usage:
  bash check-build-environment.sh [--project /path/to/exit_ip_widget] [--test]

Options:
  --project PATH  Source-kit root containing Package.swift, Sources/, and Configuration/.
  --test          Run `swift test` after the preflight passes.
  --help          Show this help text.
EOF
}

sdk_major() {
    printf '%s' "${1%%.*}"
}

is_project_root() {
    local candidate="$1"
    [[ -f "$candidate/Package.swift" && -d "$candidate/Sources" && -d "$candidate/Configuration" ]]
}

absolute_path() {
    local candidate="$1"
    (cd "$candidate" && pwd)
}

while (( $# > 0 )); do
    case "$1" in
        --project)
            if (( $# < 2 )); then
                printf 'ERROR --project requires a path.\n' >&2
                usage >&2
                exit 2
            fi
            project_override="$2"
            shift 2
            ;;
        --project=*)
            project_override="${1#--project=}"
            shift
            ;;
        --test)
            run_tests=1
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            printf 'ERROR Unknown option: %s\n' "$1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CURRENT_DIR="$(pwd)"
PROJECT_ROOT=""

if [[ -n "$project_override" ]]; then
    if [[ -d "$project_override" ]] && is_project_root "$project_override"; then
        PROJECT_ROOT="$(absolute_path "$project_override")"
        project_available=1
    else
        fail "--project does not point to an extracted source-kit root: $project_override"
    fi
else
    # Supports both the normal Scripts/ location and a copied script run from Downloads.
    for candidate in \
        "$SCRIPT_DIR/.." \
        "$CURRENT_DIR" \
        "$CURRENT_DIR/exit_ip_widget" \
        "$SCRIPT_DIR" \
        "$SCRIPT_DIR/exit_ip_widget" \
        "$SCRIPT_DIR/../exit_ip_widget"; do
        if [[ -d "$candidate" ]] && is_project_root "$candidate"; then
            PROJECT_ROOT="$(absolute_path "$candidate")"
            project_available=1
            break
        fi
    done
    if (( project_available == 0 )); then
        fail "Source-kit root not found. Run the script inside the extracted exit_ip_widget folder or pass --project /path/to/exit_ip_widget."
    fi
fi

section "Exit IP Monitor macOS build preflight"
if (( project_available == 1 )); then
    printf 'Source-kit root: %s\n' "$PROJECT_ROOT"
else
    printf 'Source-kit root: not located\n'
fi
printf 'Mode: %s\n' "$([[ $run_tests -eq 1 ]] && printf '%s' '--test' || printf '%s' 'check only')"

if [[ "$(uname -s)" != "Darwin" ]]; then
    fail "This is not macOS. Build the SwiftUI app and WidgetKit extension on a Mac with full Xcode."
    printf '\nResult: %d blocking issue(s), %d warning(s).\n' "$blocking_failures" "$warnings"
    exit 1
fi

section "macOS host"
macos_version="$(sw_vers -productVersion)"
IFS='.' read -r os_major os_minor _ <<< "$macos_version"
os_major="${os_major:-0}"
os_minor="${os_minor:-0}"
printf 'macOS: %s\n' "$macos_version"

if (( os_major > 15 || (os_major == 15 && os_minor >= 6) )); then
    pass "Host macOS can support an Xcode 26-or-newer toolchain."
else
    fail "Xcode 26 requires macOS Sequoia 15.6 or later. Update macOS before installing the required Xcode release."
fi

if (( os_major >= 26 )); then
    pass "The Control Center control can run locally on this macOS version."
else
    warn "The menu-bar app and normal WidgetKit widget can build, but the Control Center control requires macOS 26+ at runtime."
fi

section "Developer directory and Xcode"
if [[ -n "${DEVELOPER_DIR:-}" ]]; then
    developer_dir="$DEVELOPER_DIR"
    printf 'DEVELOPER_DIR override: %s\n' "$developer_dir"
else
    developer_dir="$(xcode-select -p 2>/dev/null || true)"
fi

xcode_apps=()
shopt -s nullglob
for app in /Applications/Xcode*.app "$HOME"/Applications/Xcode*.app; do
    [[ -d "$app/Contents/Developer" ]] && xcode_apps+=("$app")
done
shopt -u nullglob

if [[ -z "$developer_dir" ]]; then
    if (( ${#xcode_apps[@]} > 0 )); then
        fail "No active developer directory. Full Xcode was found at ${xcode_apps[0]}. Select it with: sudo xcode-select --switch \"${xcode_apps[0]}/Contents/Developer\""
    else
        fail "No active developer directory and no Xcode app was found in /Applications or ~/Applications. Install full Xcode first."
    fi
elif [[ "$developer_dir" == /Library/Developer/CommandLineTools* ]]; then
    if (( ${#xcode_apps[@]} > 0 )); then
        fail "Command Line Tools are active at $developer_dir, but full Xcode was found at ${xcode_apps[0]}. Select it first: sudo xcode-select --switch \"${xcode_apps[0]}/Contents/Developer\""
    else
        fail "Only Command Line Tools are active at $developer_dir and no full Xcode app was found in /Applications or ~/Applications. Install full Xcode."
    fi
elif [[ "$developer_dir" == *.app/Contents/Developer ]]; then
    full_xcode_active=1
    pass "Active full Xcode developer directory: $developer_dir"
else
    fail "The active developer directory is not a recognized full Xcode path: $developer_dir. Select an Xcode.app/Contents/Developer directory."
fi

if (( full_xcode_active == 1 )); then
    if xcode_version="$(xcodebuild -version 2>/dev/null)"; then
        pass "$(printf '%s' "$xcode_version" | tr '\n' ';')"
    else
        fail "xcodebuild cannot run from the selected Xcode. Re-select Xcode and complete first-launch setup."
    fi

    if ! xcodebuild -checkFirstLaunchStatus >/dev/null 2>&1; then
        fail "Xcode first-launch components are incomplete. Run: sudo xcodebuild -runFirstLaunch"
    else
        pass "Xcode first-launch components are installed."
    fi

    if ! xcodebuild -license check >/dev/null 2>&1; then
        fail "The Xcode license is not accepted. Run: sudo xcodebuild -license accept"
    else
        pass "Xcode license is accepted."
    fi
else
    warn "Skipped xcodebuild, first-launch, and license checks until a full Xcode developer directory is active."
fi

section "SDK and Swift"
if (( full_xcode_active == 1 )); then
    if sdk_version="$(xcrun --sdk macosx --show-sdk-version 2>/dev/null)"; then
        current_sdk_major="$(sdk_major "$sdk_version")"
        if (( current_sdk_major >= MINIMUM_SDK_MAJOR )); then
            pass "macOS SDK $sdk_version is sufficient for the macOS 26 ControlWidget API."
        else
            fail "macOS SDK $sdk_version is too old. Install or select Xcode with a macOS 26-or-newer SDK."
        fi
    else
        fail "The macOS SDK cannot be located through selected Xcode. Reinstall or re-select full Xcode."
    fi

    if swift_version="$(xcrun swift --version 2>/dev/null | head -n 1)"; then
        pass "$swift_version"
    else
        fail "The Swift compiler is unavailable through selected Xcode. Reinstall or re-select full Xcode."
    fi
else
    if clt_sdk="$(xcrun --sdk macosx --show-sdk-version 2>/dev/null)"; then
        warn "Command Line Tools exposes macOS SDK $clt_sdk, but this check is deferred until full Xcode is selected."
    else
        warn "Skipped SDK and Swift verification until full Xcode is selected."
    fi
fi

section "Project files and signing prerequisites"
if (( project_available == 1 )); then
    cd "$PROJECT_ROOT"
    for path in \
        Configuration/ExitIPMonitor.entitlements \
        Configuration/ExitIPMonitorWidgets.entitlements \
        Configuration/ExitIPMonitor-Info.plist \
        Configuration/ExitIPMonitorWidgets-Info.plist \
        Sources/ExitIPMonitorApp/ExitIPMonitorApp.swift \
        Sources/ExitIPMonitorWidgets/ExitIPControl.swift \
        Scripts/generate-xcode-project.sh; do
        if [[ -f "$path" ]]; then
            pass "Found $path"
        else
            fail "Missing $path. Re-extract the source kit before creating the Xcode targets."
        fi
    done

    if command -v plutil >/dev/null 2>&1 \
        && plutil -lint Configuration/ExitIPMonitor.entitlements Configuration/ExitIPMonitorWidgets.entitlements Configuration/ExitIPMonitor-Info.plist Configuration/ExitIPMonitorWidgets-Info.plist >/dev/null 2>&1; then
        pass "Entitlement and Info.plist files pass plutil validation."
    else
        fail "An entitlement or Info.plist file is invalid. Re-extract the source kit or inspect the plist syntax."
    fi

    if grep -R -E -q 'group\.com\.example\.exitipmonitor' Sources Configuration 2>/dev/null; then
        warn "The placeholder App Group identifier is still present. Replace it consistently in AppGroupStorage.swift and both entitlement files before signing."
    else
        pass "No placeholder App Group identifier remains in source or entitlements."
    fi
else
    warn "Skipped source-file, plist, App Group, and shared-core test checks because the source-kit root was not located."
fi

if command -v security >/dev/null 2>&1; then
    identities="$(security find-identity -v -p codesigning 2>/dev/null || true)"
    if grep -q '0 valid identities found' <<< "$identities"; then
        warn "No local signing identity is visible. In Xcode, sign in to an Apple Account, select the developer team, and enable Automatically manage signing."
    else
        pass "At least one local code-signing identity is available."
    fi
fi

section "Optional shared-core tests"
if (( run_tests == 1 )); then
    if (( blocking_failures == 0 && project_available == 1 && full_xcode_active == 1 )); then
        test_log="$PROJECT_ROOT/swift-test.log"
        printf 'Running: xcrun swift test --package-path "%s" --verbose 2>&1 | tee "%s"\n' "$PROJECT_ROOT" "$test_log"
        if xcrun swift test --package-path "$PROJECT_ROOT" --verbose 2>&1 | tee "$test_log"; then
            pass "Shared-core tests passed."
        else
            fail "Shared-core tests failed. The first earlier error: line in $test_log is actionable; the final Build failed and fatalError lines are summaries."
        fi
        printf 'Running: bash Tests/ExitIPDaemonTests/run.sh\n'
        if /bin/bash "$PROJECT_ROOT/Tests/ExitIPDaemonTests/run.sh"; then
            pass "Daemon script tests passed."
        else
            fail "Daemon script tests failed. The first FAIL: line above names the check."
        fi
    else
        warn "Skipped swift test until the full Xcode and source-kit checks pass."
    fi
else
    printf 'Run again with --test to execute swift test after the preflight passes.\n'
fi

printf '\nResult: %d blocking issue(s), %d warning(s).\n' "$blocking_failures" "$warnings"
if (( blocking_failures > 0 )); then
    printf 'See the matching recovery command in README.md under “Build-environment preflight and recovery.”\n'
    exit 1
fi

printf 'Environment is ready for the Xcode target-creation steps.\n'
