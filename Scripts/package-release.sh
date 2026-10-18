#!/usr/bin/env bash
# Builds a universal (arm64 + x86_64) Release app, ad-hoc signs it, verifies the
# signature, and packages it for a GitHub release: an app zip for the Homebrew cask
# (jxz345/tap/exit-ip-monitor), an Installer package (.pkg), an install.sh, and SHA256SUMS.
#
#   bash Scripts/package-release.sh [generator options, e.g. --app-group ID]
#
# Output: dist/ExitIPMonitor-<version>.zip, .pkg, install.sh, and SHA256SUMS.
# The package is unsigned (signing needs a Developer ID Installer certificate), so a
# downloaded copy needs one Gatekeeper approval (Open Anyway). Its preinstall and
# postinstall scripts (Scripts/pkg/) quit a running copy and launch the new one.
# install.sh (from Scripts/install-release.sh) installs the app from the downloaded
# .pkg without Installer or Gatekeeper, or downloads the .pkg from the GitHub release
# v<version> of the origin remote (set EXIT_IP_RELEASE_REPO=owner/repo to override).
#
# Publish releases from .github/workflows/release.yml (push a v<version> tag), not from a
# local run. The script checks for unwanted archive metadata; a locally created
# com.apple.provenance attribute alone does not diagnose a Gatekeeper failure.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KIT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_DIR="$KIT_ROOT/XcodeProject"
DERIVED_DATA="$PROJECT_DIR/DerivedData-Release"
DIST_DIR="$KIT_ROOT/dist"
APP_BUNDLE="$DERIVED_DATA/Build/Products/Release/ExitIPMonitor.app"

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    sed -n '2,19p' "$0"
    exit 0
fi

source "$SCRIPT_DIR/lib/adhoc-sign.sh"

printf '== Generating Xcode project ==\n'
bash "$SCRIPT_DIR/generate-xcode-project.sh" --force --skip-tests --generate-only "$@"

printf '\n== Building universal Release app ==\n'
rm -rf "$DERIVED_DATA"
xcodebuild \
    -project "$PROJECT_DIR/ExitIPMonitor.xcodeproj" \
    -scheme ExitIPMonitor \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "$DERIVED_DATA" \
    ARCHS="arm64 x86_64" \
    ONLY_ACTIVE_ARCH=NO \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    build

printf '\n== Ad-hoc signing ==\n'
adhoc_sign_app "$APP_BUNDLE" "$PROJECT_DIR/Configuration/ExitIPMonitorWidgets.entitlements"

for binary in \
    "$APP_BUNDLE/Contents/MacOS/ExitIPMonitor" \
    "$APP_BUNDLE/Contents/PlugIns/ExitIPMonitorWidgets.appex/Contents/MacOS/ExitIPMonitorWidgets"; do
    archs="$(lipo -archs "$binary")"
    if [[ " $archs " != *" arm64 "* || " $archs " != *" x86_64 "* ]]; then
        printf 'ERROR %s is not universal (archs: %s)\n' "$binary" "$archs" >&2
        exit 1
    fi
    printf 'PASS  Universal (%s): %s\n' "$archs" "${binary#"$APP_BUNDLE/"}"
done

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_BUNDLE/Contents/Info.plist")"
bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_BUNDLE/Contents/Info.plist")"
pkg_path="$DIST_DIR/ExitIPMonitor-$version.pkg"
mkdir -p "$DIST_DIR"
zip_path="$DIST_DIR/ExitIPMonitor-$version.zip"
rm -f "$pkg_path" "$zip_path" "$DIST_DIR/SHA256SUMS" "$DIST_DIR"/ExitIPMonitor-*.dmg

# App zip for the Homebrew cask (jxz345/tap/exit-ip-monitor). ditto keeps the signature
# intact; Finder's zip or `zip -r` can break it. No extended attributes: see the check below.
ditto -c -k --norsrc --noextattr --keepParent "$APP_BUNDLE" "$zip_path"

# Installer package. Installer does not quarantine what it installs, so after the one
# Gatekeeper approval of the package, the app launches without a second prompt.
printf '\n== Building installer package ==\n'
pkg_work="$(mktemp -d -t exit-ip-pkg)"
trap 'rm -rf "$pkg_work"' EXIT
mkdir -p "$pkg_work/root" "$pkg_work/packages"
ditto "$APP_BUNDLE" "$pkg_work/root/ExitIPMonitor.app"
pkgbuild --analyze --root "$pkg_work/root" "$pkg_work/components.plist"
# Always install to /Applications: a relocatable bundle would update whichever copy with the same
# bundle ID Installer finds first (a build folder, a scratch copy). Allow same-version reinstalls.
plutil -replace 0.BundleIsRelocatable -bool NO "$pkg_work/components.plist"
plutil -replace 0.BundleIsVersionChecked -bool NO "$pkg_work/components.plist"
plutil -replace 0.BundleOverwriteAction -string upgrade "$pkg_work/components.plist"
pkgbuild \
    --root "$pkg_work/root" \
    --component-plist "$pkg_work/components.plist" \
    --install-location /Applications \
    --scripts "$SCRIPT_DIR/pkg" \
    --identifier "$bundle_id.pkg" \
    --version "$version" \
    "$pkg_work/packages/ExitIPMonitor.pkg"
productbuild --synthesize --package "$pkg_work/packages/ExitIPMonitor.pkg" "$pkg_work/distribution.xml"
# Title and minimum macOS for the Installer window; synthesize already lists both architectures.
/usr/bin/sed -i '' \
    -e "s|<installer-gui-script minSpecVersion=\"\([0-9]*\)\">|<installer-gui-script minSpecVersion=\"\\1\">\\
    <title>Exit IP Monitor $version</title>\\
    <allowed-os-versions><os-version min=\"14.0\"/></allowed-os-versions>|" \
    "$pkg_work/distribution.xml"
grep -q '<title>' "$pkg_work/distribution.xml" || { printf 'ERROR Could not set the installer title.\n' >&2; exit 1; }
grep -q 'hostArchitectures="[^"]*arm64' "$pkg_work/distribution.xml" \
    || { printf 'ERROR The installer distribution does not allow arm64 (Installer would ask for Rosetta).\n' >&2; exit 1; }
productbuild --distribution "$pkg_work/distribution.xml" --package-path "$pkg_work/packages" "$pkg_path"

# The packaged app must be the signed, sealed bundle.
pkgutil --expand-full "$pkg_path" "$pkg_work/check"
packaged_app="$(find "$pkg_work/check" -maxdepth 4 -name ExitIPMonitor.app -type d | head -1)"
[[ -n "$packaged_app" ]] || { printf 'ERROR The package does not contain ExitIPMonitor.app.\n' >&2; exit 1; }
codesign --verify --deep --strict "$packaged_app" || { printf 'ERROR The packaged app signature does not verify.\n' >&2; exit 1; }
printf 'PASS  Package contains the signed app: %s\n' "$pkg_path"

pkg_sha="$(shasum -a 256 "$pkg_path" | awk '{print $1}')"
install_path="$DIST_DIR/install.sh"
release_repo="${EXIT_IP_RELEASE_REPO:-}"
if [[ -z "$release_repo" ]]; then
    origin_url="$(git -C "$KIT_ROOT" remote get-url origin 2>/dev/null || true)"
    if [[ "$origin_url" =~ github\.com[:/]([^/]+/[^/]+)$ ]]; then
        release_repo="${BASH_REMATCH[1]%.git}"
    fi
fi
rm -f "$install_path"
if [[ -n "$release_repo" ]]; then
    sed -e "s|@RELEASE_REPO@|$release_repo|" \
        -e "s|@VERSION@|$version|" \
        -e "s|@PKG_SHA256@|$pkg_sha|" \
        "$SCRIPT_DIR/install-release.sh" | awk -v support="$KIT_ROOT/Sources/ExitIPDiagnostics/command-support.sh" '
            /^# @COMMAND_SUPPORT@$/ { while ((getline line < support) > 0) print line; close(support); next }
            { print }
        ' > "$install_path"
    chmod +x "$install_path"
else
    printf 'WARN  No GitHub origin remote; skipping install.sh (set EXIT_IP_RELEASE_REPO=owner/repo).\n'
fi

# Keep release archives free of AppleDouble metadata. This is archive hygiene, not a
# Gatekeeper readiness test: macOS may add provenance locally after extraction.
apple_double='(^|/)\._|^__MACOSX/'
stamped=()
(( $(zipinfo -1 "$zip_path" | grep -cE "$apple_double" || true) == 0 )) || stamped+=("$(basename "$zip_path")")
(( $(pkgutil --payload-files "$pkg_path" | grep -cE "$apple_double" || true) == 0 )) || stamped+=("$(basename "$pkg_path")")
if (( ${#stamped[@]} > 0 )); then
    if [[ "${CI:-}" == "true" ]]; then
        printf 'ERROR Extended attributes (AppleDouble entries) in: %s\n' "${stamped[*]}" >&2
        exit 1
    fi
    printf 'WARN  AppleDouble metadata in: %s\n' "${stamped[*]}"
    printf '      Publish releases from .github/workflows/release.yml.\n'
else
    printf 'PASS  No AppleDouble entries in the zip or package.\n'
fi

(
    cd "$DIST_DIR"
    artifacts=("$(basename "$pkg_path")" "$(basename "$zip_path")")
    [[ -f "$install_path" ]] && artifacts+=("$(basename "$install_path")")
    shasum -a 256 "${artifacts[@]}" > SHA256SUMS
)

printf '\nSUCCESS\n'
cat "$DIST_DIR/SHA256SUMS"
printf '\nCask values for jxz345/homebrew-tap Casks/exit-ip-monitor.rb:\n'
printf '  version "%s"\n  sha256 "%s"\n' "$version" "$(shasum -a 256 "$zip_path" | awk '{print $1}')"
if [[ "${CI:-}" != "true" ]]; then
    printf 'To publish, push the tag v%s; .github/workflows/release.yml builds and uploads on a clean runner.\n' "$version"
fi
