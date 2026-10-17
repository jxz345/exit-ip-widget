# Sourced helper: ad-hoc sign an unsigned ExitIPMonitor.app bundle.
#
# A build with CODE_SIGNING_ALLOWED=NO keeps only the linker's partial ad-hoc
# signature, which seals neither Info.plist nor resources. Once a download or
# AirDrop quarantines that bundle, Gatekeeper reports it as "damaged". Signing
# the extension and then the app (inside out) produces a complete ad-hoc
# signature that verifies on any Mac.
#
# The app is signed without entitlements, so it runs unsandboxed. That is the
# configuration every linker-signed build already ran in, because a linker-only
# signature never applied the entitlements. It keeps data in
# ~/Library/Preferences and ~/Library/Application Support. A sandboxed ad-hoc
# app cannot use the App Group (only a team provisioning profile authorizes one),
# and its container would be tied to a signature that changes with every build.
# App extensions must be sandboxed, so the widget keeps its sandbox entitlement
# without the App Group. As with any build lacking a registered App Group, it
# cannot read the app's data. --signed-build keeps the full entitlements.
#
#   adhoc_sign_app APP_BUNDLE WIDGET_ENTITLEMENTS

adhoc_sign_app() {
    local app="$1"
    local widget_entitlements_source="$2"
    local widget="$app/Contents/PlugIns/ExitIPMonitorWidgets.appex"
    local nested work status=0

    [[ -d "$app" ]] || { printf 'ERROR App bundle not found: %s\n' "$app" >&2; return 1; }

    work="$(mktemp -d -t exit-ip-adhoc)" || return 1
    local widget_entitlements="$work/widget.entitlements"
    cp "$widget_entitlements_source" "$widget_entitlements" || { rm -rf "$work"; return 1; }
    /usr/libexec/PlistBuddy -c 'Delete :com.apple.security.application-groups' "$widget_entitlements" >/dev/null 2>&1 || true

    (
        # Embedded frameworks/dylibs first, if any are ever added.
        while IFS= read -r -d '' nested; do
            codesign --force --sign - --timestamp=none "$nested" || exit 1
        done < <(find "$app/Contents" \( -name '*.framework' -o -name '*.dylib' \) -prune -print0 2>/dev/null)

        if [[ -d "$widget" ]]; then
            codesign --force --sign - --timestamp=none --entitlements "$widget_entitlements" "$widget" || exit 1
        fi
        codesign --force --sign - --timestamp=none "$app" || exit 1
    ) || status=1
    rm -rf "$work"
    (( status == 0 )) || { printf 'ERROR Ad-hoc signing failed: %s\n' "$app" >&2; return 1; }

    if ! codesign --verify --deep --strict --verbose=2 "$app"; then
        printf 'ERROR Ad-hoc signature does not verify: %s\n' "$app" >&2
        return 1
    fi
    printf 'PASS  Ad-hoc signed (bundle sealed; app unsandboxed, widget sandboxed): %s\n' "$app"
}
