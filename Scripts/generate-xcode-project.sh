#!/usr/bin/env bash
# Generates a self-contained Xcode project, copies the supplied sources into it,
# runs the shared Swift package tests, and performs an unsigned compilation build
# that is then ad-hoc signed (see Scripts/lib/adhoc-sign.sh).
#
# Usage:
#   bash Scripts/generate-xcode-project.sh
#   bash Scripts/generate-xcode-project.sh --force
#   bash Scripts/generate-xcode-project.sh --app-group group.com.example.exitipmonitor --team ABCDE12345 --signed-build
#
# The script downloads only XcodeGen's release artifact when `xcodegen` is not
# available. It does not download or package a Swift toolchain.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KIT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_DIR="$KIT_ROOT/XcodeProject"
LOG_DIR="$PROJECT_DIR/Logs"
TIMESTAMP="$(date '+%Y%m%d-%H%M%S')"
LOG_PATH="$LOG_DIR/generate-and-build-$TIMESTAMP-$$.log"

APP_GROUP="group.com.example.exitipmonitor"
BUNDLE_ID="com.example.exitipmonitor"
TEAM_ID=""
FORCE=0
SKIP_TESTS=0
GENERATE_ONLY=0
SIGNED_BUILD=0
OPEN_PROJECT=0
ALLOW_XCODEGEN_DOWNLOAD=1
XCODEGEN_VERSION="2.46.0"
XCODEGEN_BIN=""

mkdir -p "$LOG_DIR"
: > "$LOG_PATH"
exec > >(tee -a "$LOG_PATH") 2>&1

on_exit() {
    local status=$?
    if (( status != 0 )); then
        printf '\nFAILED (exit %d). Attach this file for diagnosis:\n%s\n' "$status" "$LOG_PATH" >&2
    fi
}
trap on_exit EXIT

usage() {
    cat <<'EOF'
Usage:
  bash Scripts/generate-xcode-project.sh [options]

Options:
  --app-group ID         App Group to write into the copied sources and entitlements.
                         Default: group.com.example.exitipmonitor (compile-only placeholder)
  --bundle-id ID         Containing app bundle identifier.
                         Default: com.example.exitipmonitor
  --team TEAM_ID         Apple Developer Team ID. Required only for --signed-build.
  --signed-build         Build with signing enabled. Requires a real --team and --app-group.
  --force                Replace generated Sources/, Configuration/, project.yml, and .xcodeproj.
  --skip-tests           Do not run the shared Swift Package Manager tests first.
  --generate-only        Create project files but do not invoke xcodebuild.
  --open                 Open the generated .xcodeproj after a successful run.
  --no-download-xcodegen Fail instead of downloading XcodeGen when it is not already installed.
  --help                 Show this help text.

Output:
  XcodeProject/ExitIPMonitor.xcodeproj
  XcodeProject/Logs/generate-and-build-YYYYMMDD-HHMMSS.log
EOF
}

require_value() {
    local option="$1"
    local remaining="$2"
    if (( remaining < 2 )); then
        printf 'ERROR %s requires a value.\n' "$option" >&2
        usage >&2
        exit 2
    fi
}

validate_bundle_id() {
    [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*[A-Za-z0-9]$ ]]
}

validate_app_group() {
    [[ "$1" =~ ^group\.[A-Za-z0-9][A-Za-z0-9.-]*[A-Za-z0-9]$ ]]
}

while (( $# > 0 )); do
    case "$1" in
        --app-group)
            require_value "$1" "$#"
            APP_GROUP="$2"
            shift 2
            ;;
        --bundle-id)
            require_value "$1" "$#"
            BUNDLE_ID="$2"
            shift 2
            ;;
        --team)
            require_value "$1" "$#"
            TEAM_ID="$2"
            shift 2
            ;;
        --force)
            FORCE=1
            shift
            ;;
        --skip-tests)
            SKIP_TESTS=1
            shift
            ;;
        --generate-only)
            GENERATE_ONLY=1
            shift
            ;;
        --signed-build)
            SIGNED_BUILD=1
            shift
            ;;
        --open)
            OPEN_PROJECT=1
            shift
            ;;
        --no-download-xcodegen)
            ALLOW_XCODEGEN_DOWNLOAD=0
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

if ! validate_bundle_id "$BUNDLE_ID"; then
    printf 'ERROR --bundle-id must be a reverse-DNS-style identifier.\n' >&2
    exit 2
fi
if ! validate_app_group "$APP_GROUP"; then
    printf 'ERROR --app-group must begin with group. and contain only letters, numbers, dots, and hyphens.\n' >&2
    exit 2
fi
if [[ -n "$TEAM_ID" && ! "$TEAM_ID" =~ ^[A-Za-z0-9]+$ ]]; then
    printf 'ERROR --team must contain only letters and numbers.\n' >&2
    exit 2
fi
if (( SIGNED_BUILD == 1 )) && [[ -z "$TEAM_ID" ]]; then
    printf 'ERROR --signed-build requires --team YOUR_TEAM_ID.\n' >&2
    exit 2
fi
if (( SIGNED_BUILD == 1 )) && [[ "$APP_GROUP" == "group.com.example.exitipmonitor" ]]; then
    printf 'ERROR --signed-build requires a registered, non-placeholder --app-group.\n' >&2
    exit 2
fi

printf '== Exit IP Monitor project generator ==\n'
printf 'Source kit: %s\n' "$KIT_ROOT"
printf 'Output project: %s\n' "$PROJECT_DIR"
printf 'Log file: %s\n' "$LOG_PATH"
printf 'Bundle ID: %s\n' "$BUNDLE_ID"
printf 'App Group: %s\n' "$APP_GROUP"

for required_path in \
    "$KIT_ROOT/Package.swift" \
    "$KIT_ROOT/Sources/ExitIPShared/AppGroupIdentifier.swift" \
    "$KIT_ROOT/Sources/ExitIPMonitorApp/ExitIPMonitorApp.swift" \
    "$KIT_ROOT/Sources/ExitIPMonitorWidgets/ExitIPControl.swift" \
    "$KIT_ROOT/Configuration/ExitIPMonitor-Info.plist" \
    "$KIT_ROOT/Configuration/ExitIPMonitorWidgets-Info.plist" \
    "$KIT_ROOT/Configuration/ExitIPMonitor.entitlements" \
    "$KIT_ROOT/Configuration/ExitIPMonitorWidgets.entitlements"; do
    [[ -f "$required_path" ]] || { printf 'ERROR Required source-kit file is missing: %s\n' "$required_path" >&2; exit 1; }
done

if [[ "$(uname -s)" != "Darwin" ]]; then
    printf 'ERROR This script must run on macOS because it creates and builds an Xcode project.\n' >&2
    exit 1
fi

developer_dir="$(xcode-select -p 2>/dev/null || true)"
if [[ "$developer_dir" != *.app/Contents/Developer ]]; then
    printf 'ERROR Full Xcode is not selected. Run: sudo xcode-select --switch "/Applications/Xcode.app/Contents/Developer"\n' >&2
    exit 1
fi

xcodebuild -version
sdk_version="$(xcrun --sdk macosx --show-sdk-version)"
sdk_major="${sdk_version%%.*}"
if (( sdk_major < 26 )); then
    printf 'ERROR macOS SDK %s is too old for the Control Center API. Select Xcode with a macOS 26-or-newer SDK.\n' "$sdk_version" >&2
    exit 1
fi
printf 'PASS  Selected SDK: macOS %s\n' "$sdk_version"

if (( SKIP_TESTS == 0 )); then
    printf '\n== Shared-core SwiftPM tests ==\n'
    xcrun swift test --package-path "$KIT_ROOT" --verbose
else
    printf '\nSKIP  Shared-core SwiftPM tests (--skip-tests).\n'
fi

# Protect hand-edited projects: only refresh generator-owned content when --force is explicit.
if [[ -e "$PROJECT_DIR/ExitIPMonitor.xcodeproj" || -e "$PROJECT_DIR/project.yml" || -d "$PROJECT_DIR/Sources" || -d "$PROJECT_DIR/Configuration" ]]; then
    if (( FORCE == 0 )); then
        printf '\nERROR Generated project content already exists. Re-run with --force to refresh it.\n' >&2
        exit 1
    fi
    printf '\n== Refreshing generated project content ==\n'
    rm -rf \
        "$PROJECT_DIR/ExitIPMonitor.xcodeproj" \
        "$PROJECT_DIR/Sources" \
        "$PROJECT_DIR/Configuration" \
        "$PROJECT_DIR/project.yml" \
        "$PROJECT_DIR/DerivedData"
fi

printf '\n== Copying source kit into self-contained project ==\n'
mkdir -p "$PROJECT_DIR"
ditto "$KIT_ROOT/Sources" "$PROJECT_DIR/Sources"
ditto "$KIT_ROOT/Configuration" "$PROJECT_DIR/Configuration"
find "$PROJECT_DIR/Sources" "$PROJECT_DIR/Configuration" -name '.DS_Store' -delete

# Apply the requested App Group only to generated copies. The source kit remains reusable.
# macOS ships BSD sed (`-i ''`), while the validation environment uses GNU sed (`-i`).
replace_app_group() {
    local path="$1"
    local expression="s|group\\.com\\.example\\.exitipmonitor|$APP_GROUP|g"
    if /usr/bin/sed --version >/dev/null 2>&1; then
        /usr/bin/sed -i "$expression" "$path"
    else
        /usr/bin/sed -i '' "$expression" "$path"
    fi
}

for path in \
    "$PROJECT_DIR/Sources/ExitIPShared/AppGroupIdentifier.swift" \
    "$PROJECT_DIR/Configuration/ExitIPMonitor.entitlements" \
    "$PROJECT_DIR/Configuration/ExitIPMonitorWidgets.entitlements"; do
    replace_app_group "$path"
done

TEAM_SETTING=""
if [[ -n "$TEAM_ID" ]]; then
    TEAM_SETTING="        DEVELOPMENT_TEAM: $TEAM_ID"
fi

printf '\n== Writing XcodeGen project specification ==\n'
cat > "$PROJECT_DIR/project.yml" <<EOF
name: ExitIPMonitor
options:
  minimumXcodeGenVersion: $XCODEGEN_VERSION
  deploymentTarget:
    macOS: "14.0"
settings:
  base:
    SWIFT_VERSION: "6.0"
    MACOSX_DEPLOYMENT_TARGET: "14.0"
    MARKETING_VERSION: "1.0"
    CURRENT_PROJECT_VERSION: "1"
targets:
  ExitIPMonitor:
    type: application
    platform: macOS
    deploymentTarget: "14.0"
    sources:
      - path: Sources/ExitIPShared
      - path: Sources/ExitIPMonitorApp
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: $BUNDLE_ID
        PRODUCT_NAME: ExitIPMonitor
        GENERATE_INFOPLIST_FILE: NO
        INFOPLIST_FILE: Configuration/ExitIPMonitor-Info.plist
        CODE_SIGN_ENTITLEMENTS: Configuration/ExitIPMonitor.entitlements
        CODE_SIGN_STYLE: Automatic
$TEAM_SETTING
    dependencies:
      - target: ExitIPMonitorWidgets
        embed: true
        codeSign: true
      - sdk: AppIntents.framework
      - sdk: Network.framework
      - sdk: Security.framework
      - sdk: ServiceManagement.framework
      - sdk: SystemConfiguration.framework
      - sdk: WidgetKit.framework
    scheme:
      gatherCoverageData: false

  ExitIPMonitorWidgets:
    type: app-extension
    platform: macOS
    deploymentTarget: "14.0"
    sources:
      - path: Sources/ExitIPShared
      - path: Sources/ExitIPMonitorApp/ExitIPIntents.swift
      - path: Sources/ExitIPMonitorWidgets
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: $BUNDLE_ID.widgets
        PRODUCT_NAME: ExitIPMonitorWidgets
        GENERATE_INFOPLIST_FILE: NO
        INFOPLIST_FILE: Configuration/ExitIPMonitorWidgets-Info.plist
        CODE_SIGN_ENTITLEMENTS: Configuration/ExitIPMonitorWidgets.entitlements
        CODE_SIGN_STYLE: Automatic
$TEAM_SETTING
    dependencies:
      - sdk: AppIntents.framework
      - sdk: WidgetKit.framework
EOF

resolve_xcodegen() {
    if [[ -n "${XCODEGEN_PATH:-}" ]]; then
        [[ -x "$XCODEGEN_PATH" ]] || { printf 'ERROR XCODEGEN_PATH is not executable: %s\n' "$XCODEGEN_PATH" >&2; exit 1; }
        XCODEGEN_BIN="$XCODEGEN_PATH"
        return
    fi

    if command -v xcodegen >/dev/null 2>&1; then
        XCODEGEN_BIN="$(command -v xcodegen)"
        return
    fi

    local tools_dir="$PROJECT_DIR/.tools"
    local artifact_dir="$tools_dir/xcodegen.artifactbundle"
    local artifact_zip="$tools_dir/xcodegen.artifactbundle.zip"
    local download_url="https://github.com/yonaskolb/XcodeGen/releases/download/$XCODEGEN_VERSION/xcodegen.artifactbundle.zip"

    if [[ -d "$artifact_dir" ]]; then
        local cached_artifact_binary
        cached_artifact_binary="$(find "$artifact_dir" -type f -name xcodegen -perm -111 | head -n 1 || true)"
        if [[ -n "$cached_artifact_binary" ]]; then
            # Keep the executable next to XcodeGen_XcodeGenKit.bundle; it loads settings from that bundle.
            XCODEGEN_BIN="$cached_artifact_binary"
            return
        fi
    fi

    if (( ALLOW_XCODEGEN_DOWNLOAD == 0 )); then
        printf 'ERROR XcodeGen is not installed. Install it with `brew install xcodegen`, set XCODEGEN_PATH, or rerun without --no-download-xcodegen.\n' >&2
        exit 1
    fi

    printf '\n== Downloading XcodeGen %s ==\n' "$XCODEGEN_VERSION"
    printf 'Source: %s\n' "$download_url"
    mkdir -p "$tools_dir"
    /usr/bin/curl --fail --location --show-error --progress-bar -o "$artifact_zip" "$download_url"
    rm -rf "$artifact_dir"
    /usr/bin/unzip -oq "$artifact_zip" -d "$tools_dir"

    local artifact_binary
    artifact_binary="$(find "$tools_dir" -type f -name xcodegen -perm -111 | head -n 1 || true)"
    if [[ -z "$artifact_binary" ]]; then
        printf 'ERROR XcodeGen artifact did not contain an executable named xcodegen.\n' >&2
        exit 1
    fi

    XCODEGEN_BIN="$artifact_binary"
}

resolve_xcodegen
printf '\n== Generating Xcode project ==\n'
printf 'XcodeGen: %s\n' "$XCODEGEN_BIN"
"$XCODEGEN_BIN" generate --spec "$PROJECT_DIR/project.yml" --project "$PROJECT_DIR"

XCODE_PROJECT="$PROJECT_DIR/ExitIPMonitor.xcodeproj"
[[ -d "$XCODE_PROJECT" ]] || { printf 'ERROR XcodeGen did not produce: %s\n' "$XCODE_PROJECT" >&2; exit 1; }
printf 'PASS  Generated project: %s\n' "$XCODE_PROJECT"

APP_BUNDLE="$PROJECT_DIR/DerivedData/Build/Products/Debug/ExitIPMonitor.app"
APP_EXECUTABLE="$APP_BUNDLE/Contents/MacOS/ExitIPMonitor"

if (( GENERATE_ONLY == 0 )); then
    printf '\n== Building generated project ==\n'
    if (( SIGNED_BUILD == 1 )); then
        xcodebuild \
            -project "$XCODE_PROJECT" \
            -scheme ExitIPMonitor \
            -configuration Debug \
            -destination 'platform=macOS' \
            -derivedDataPath "$PROJECT_DIR/DerivedData" \
            build
    else
        printf 'Building without a signing identity, then ad-hoc signing. Use --signed-build with a registered App Group and Team ID for a team-signed app.\n'
        xcodebuild \
            -project "$XCODE_PROJECT" \
            -scheme ExitIPMonitor \
            -configuration Debug \
            -destination 'platform=macOS' \
            -derivedDataPath "$PROJECT_DIR/DerivedData" \
            CODE_SIGNING_ALLOWED=NO \
            CODE_SIGNING_REQUIRED=NO \
            build
        # Replace the linker-only signature so the bundle survives a copy to another Mac.
        source "$SCRIPT_DIR/lib/adhoc-sign.sh"
        adhoc_sign_app "$APP_BUNDLE" "$PROJECT_DIR/Configuration/ExitIPMonitorWidgets.entitlements"
    fi
    printf 'PASS  Build completed.\n'
    if [[ -d "$APP_BUNDLE" && -x "$APP_EXECUTABLE" ]]; then
        printf 'App bundle: %s\n' "$APP_BUNDLE"
        printf 'Executable: %s\n' "$APP_EXECUTABLE"
        printf 'Launch locally: open "%s"\n' "$APP_BUNDLE"
    else
        printf 'WARN  xcodebuild reported success but the expected Debug app bundle was not found at: %s\n' "$APP_BUNDLE" >&2
    fi
else
    printf '\nSKIP  xcodebuild (--generate-only).\n'
fi

if (( OPEN_PROJECT == 1 )); then
    open "$XCODE_PROJECT"
fi

printf '\nSUCCESS\n'
printf 'Xcode project: %s\n' "$XCODE_PROJECT"
printf 'Build log: %s\n' "$LOG_PATH"
if [[ -d "$APP_BUNDLE" && -x "$APP_EXECUTABLE" ]]; then
    printf 'App bundle: %s\n' "$APP_BUNDLE"
    printf 'Executable: %s\n' "$APP_EXECUTABLE"
fi
printf '\nFor a runnable signed app, register the App Group in Apple Developer, then run:\n'
printf '  bash Scripts/generate-xcode-project.sh --force --app-group %s --team YOUR_TEAM_ID --signed-build --open\n' "$APP_GROUP"
