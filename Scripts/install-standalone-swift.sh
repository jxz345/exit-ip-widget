#!/usr/bin/env bash
# Optional standalone Swift installation for Swift Package Manager tests only.
# The Exit IP Monitor macOS app and WidgetKit extension still require full Xcode.
# Source: https://www.swift.org/install/macos/
#
# Usage:
#   bash Scripts/install-standalone-swift.sh

set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
    printf 'ERROR This installer supports macOS only.\n' >&2
    exit 1
fi

SWIFTLY_PKG_URL="https://download.swift.org/swiftly/darwin/swiftly.pkg"
SWIFTLY_HOME_DIR="${SWIFTLY_HOME_DIR:-$HOME/.swiftly}"
SWIFTLY_BIN="$SWIFTLY_HOME_DIR/bin/swiftly"
temporary_directory="$(mktemp -d)"
package_path="$temporary_directory/swiftly.pkg"

cleanup() {
    rm -rf "$temporary_directory"
}
trap cleanup EXIT

printf '%s\n' 'This optional setup downloads Swiftly and one Swift toolchain from Swift.org.'
printf '%s\n' 'It is only for `swift test`; it does not replace full Xcode for the app, widget, or Control Center control.'
printf 'Downloading Swiftly from %s\n' "$SWIFTLY_PKG_URL"
curl --fail --location --show-error --progress-bar -o "$package_path" "$SWIFTLY_PKG_URL"

printf '%s\n' 'Installing Swiftly in the current user account…'
installer -pkg "$package_path" -target CurrentUserHomeDirectory

if [[ ! -x "$SWIFTLY_BIN" ]]; then
    printf 'ERROR Swiftly was not found at %s after installation.\n' "$SWIFTLY_BIN" >&2
    exit 1
fi

printf '%s\n' 'Initializing Swiftly and downloading the default Swift toolchain…'
"$SWIFTLY_BIN" init --quiet-shell-followup

# The setup modifies shell startup files. Source the environment only for this script's verification run.
if [[ -f "$SWIFTLY_HOME_DIR/env.sh" ]]; then
    # shellcheck disable=SC1090
    source "$SWIFTLY_HOME_DIR/env.sh"
fi

printf '\nInstalled standalone toolchain:\n'
swift --version
printf '\nNext steps in a new Terminal window:\n'
printf '  cd /path/to/exit_ip_widget\n'
printf '  swift test --verbose 2>&1 | tee swift-test.log\n'
printf '\nFor the Exit IP Monitor app and widget, continue to use full Xcode and `xcrun swift`; a standalone toolchain cannot build WidgetKit or Control Center targets.\n'
