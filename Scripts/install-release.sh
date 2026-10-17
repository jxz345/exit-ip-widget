#!/usr/bin/env bash
# Installs Exit IP Monitor from the release package (.pkg) and launches it, without
# Installer or Gatekeeper.
#
#   bash install.sh                      # uses a downloaded ExitIPMonitor-<version>.pkg, or downloads it
#   bash install.sh ~/Downloads/ExitIPMonitor-<version>.pkg
#   curl -fsSL <release URL>/install.sh | bash      # public repository only
#
# The package and app are not notarized. A browser or AirDrop download is
# quarantined, so macOS holds it for Gatekeeper approval (Open Anyway). That
# prompt can fail to appear. This installer checks the package's SHA-256 and the
# app's signature, unpacks the app from the package, installs it without the
# quarantine flag, and launches it, so no prompt comes up.
#
# Where the package comes from, in order:
#   1. the path given as the first argument;
#   2. the newest ExitIPMonitor-<version>*.pkg next to this script or in ~/Downloads
#      whose SHA-256 matches this release (older downloads are skipped);
#   3. a download with curl (works when the repository is public);
#   4. `gh release download` (works for a private repository when gh is logged in).
#
# Scripts/package-release.sh writes dist/install.sh from this file with the
# release values filled in. For testing, EXIT_IP_PKG_URL / EXIT_IP_PKG_SHA256
# override the download, and EXIT_IP_INSTALL_DIR the target folder
# (default /Applications, or ~/Applications when /Applications is not writable).

set -euo pipefail

RELEASE_REPO="@RELEASE_REPO@"
VERSION="@VERSION@"
PKG_SHA256="${EXIT_IP_PKG_SHA256:-@PKG_SHA256@}"
PKG_NAME="ExitIPMonitor-$VERSION.pkg"
PKG_URL="${EXIT_IP_PKG_URL:-https://github.com/$RELEASE_REPO/releases/download/v$VERSION/$PKG_NAME}"
APP_NAME="ExitIPMonitor.app"
PROCESS_NAME="ExitIPMonitor"

fail() { printf '\nERROR %s\n' "$1" >&2; exit 1; }

[[ "$(uname -s)" == "Darwin" ]] || fail "Exit IP Monitor runs on macOS only."
[[ "$RELEASE_REPO" != @* && "$PKG_SHA256" != @* ]] || fail "Use the install.sh attached to a release (made by Scripts/package-release.sh)."

if [[ -n "${EXIT_IP_INSTALL_DIR:-}" ]]; then
    install_dir="$EXIT_IP_INSTALL_DIR"
elif [[ -w /Applications ]]; then
    install_dir="/Applications"
else
    install_dir="$HOME/Applications"
fi
app_path="$install_dir/$APP_NAME"

printf '== Exit IP Monitor %s installer ==\n' "$VERSION"
printf 'macOS %s (%s)\n' "$(sw_vers -productVersion)" "$(uname -m)"

work="$(mktemp -d -t exit-ip-install)"
trap 'rm -rf "$work"' EXIT

sha_of() { shasum -a 256 "$1" | awk '{print $1}'; }

# Prints the newest package in the given folders whose SHA-256 matches this release.
# Browsers save repeat downloads as "ExitIPMonitor-1.0 (1).pkg", so older builds are skipped.
find_local_release() {
    local dir file
    for dir in "$@"; do
        [[ -n "$dir" && -d "$dir" ]] || continue
        while IFS= read -r file; do
            if [[ "$(sha_of "$file")" == "$PKG_SHA256" ]]; then
                printf '%s\n' "$file"
                return 0
            fi
        done < <(ls -t "$dir"/ExitIPMonitor-"$VERSION"*.pkg 2>/dev/null)
    done
    return 1
}

source_file="${1:-}"
if [[ -z "$source_file" ]]; then
    script_dir=""
    [[ -f "${BASH_SOURCE[0]:-}" ]] && script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    source_file="$(find_local_release "$script_dir" "$HOME/Downloads" || true)"
fi

if [[ -z "$source_file" ]]; then
    printf '\nDownloading %s\n' "$PKG_URL"
    source_file="$work/$PKG_NAME"
    if ! curl -fsSL --retry 2 -o "$source_file" "$PKG_URL" 2>"$work/curl.err"; then
        printf 'curl could not download it: %s\n' "$(grep -o 'curl: .*' "$work/curl.err" | tail -1)"
        if command -v gh >/dev/null && gh auth status >/dev/null 2>&1; then
            printf 'Downloading with gh instead...\n'
            gh release download "v$VERSION" -R "$RELEASE_REPO" -p "$PKG_NAME" -D "$work" --clobber \
                || fail "gh could not download $PKG_NAME from $RELEASE_REPO."
        else
            fail "The release could not be downloaded; a private repository needs a GitHub login.
Download $PKG_NAME from https://github.com/$RELEASE_REPO/releases/tag/v$VERSION
in a browser where you are logged in to GitHub, keep it in Downloads, then run:
  bash ~/Downloads/install.sh
(or: bash ~/Downloads/install.sh /path/to/$PKG_NAME)"
        fi
    fi
fi

[[ -f "$source_file" ]] || fail "File not found: $source_file"
printf '\nUsing: %s\n' "$source_file"
[[ "$source_file" == *.pkg ]] || fail "Pass the release .pkg, not $source_file."
[[ "$(sha_of "$source_file")" == "$PKG_SHA256" ]] \
    || fail "SHA-256 of $source_file does not match release $VERSION. Download it again."
printf 'PASS  SHA-256 matches.\n'
pkgutil --expand-full "$source_file" "$work/expanded" >/dev/null || fail "Could not unpack $source_file."
new_app="$(find "$work/expanded" -maxdepth 4 -name "$APP_NAME" -type d | head -1)"
[[ -n "$new_app" ]] || fail "$APP_NAME is missing from $source_file."
[[ -d "$new_app" ]] || fail "$APP_NAME is missing from $source_file."
codesign --verify --deep --strict "$new_app" || fail "The app's signature does not verify."
printf 'PASS  Signature verifies.\n'

if pgrep -x "$PROCESS_NAME" >/dev/null; then
    printf 'Quitting the running copy...\n'
    pkill -x "$PROCESS_NAME" || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        pgrep -x "$PROCESS_NAME" >/dev/null || break
        sleep 0.5
    done
    pkill -9 -x "$PROCESS_NAME" 2>/dev/null || true
fi

# macOS lets an app modify or replace another app's bundle only with App Management permission,
# so a refusal here usually means the terminal itself is not allowed.
app_management_hint="If the error says \"Operation not permitted\", allow the app running this script
(Terminal, or Visual Studio Code for its terminal) under System Settings > Privacy & Security >
App Management, then run the installer again."
mkdir -p "$install_dir"
if [[ -e "$app_path" ]]; then
    rm -rf "$app_path" || fail "Could not replace $app_path.
$app_management_hint"
fi
ditto "$new_app" "$app_path" || fail "Could not copy the app to $install_dir.
$app_management_hint"
xattr -dr com.apple.quarantine "$app_path" 2>/dev/null || true
printf 'PASS  Installed: %s\n' "$app_path"

open "$app_path"
for _ in $(seq 1 20); do
    pgrep -x "$PROCESS_NAME" >/dev/null && break
    sleep 0.5
done

if pgrep -x "$PROCESS_NAME" >/dev/null; then
    printf '\nSUCCESS  Exit IP Monitor is running. Its dashboard opens on first launch, and its flag is in the menu bar.\n'
    printf 'If the flag is hidden behind the notch, open the app again from Applications to show the dashboard.\n'
    exit 0
fi

printf '\nFAILED  The app did not start. Please send everything below:\n' >&2
{
    printf -- '--- signature\n'
    codesign -dvv "$app_path" 2>&1 | grep -E 'Format|flags|Sealed|Info.plist' || true
    codesign --verify --deep --strict "$app_path" 2>&1 && printf 'verifies\n'
    printf -- '--- attributes\n'
    xattr -l "$app_path" 2>&1 || true
    printf -- '--- gatekeeper\n'
    spctl -a -vv -t exec "$app_path" 2>&1 || true
    printf -- '--- system log (last minute)\n'
    /usr/bin/log show --last 1m --style compact \
        --predicate 'process == "ExitIPMonitor" OR (process == "syspolicyd" AND eventMessage CONTAINS[c] "exitip")' 2>/dev/null \
        | grep -E ' E | F |rror|deny|Prompt|crash' | tail -20 || true
} >&2
exit 1
