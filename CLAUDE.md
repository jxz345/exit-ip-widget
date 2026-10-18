# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

See also `AGENTS.md` (repo conventions), `README.md` (product behavior and provider policy), and `XCODE_ASSEMBLY.md` (manual Xcode setup).

## Commands

Run everything from the repository root (the "source-kit root").

```bash
# Shared-core tests (only builds Sources/ExitIPShared + Tests/ExitIPSharedTests)
xcrun swift test --verbose 2>&1 | tee swift-test.log
xcrun swift test --filter ExitIPSharedTests.ExitIPSharedTests/testCountryChangeConfirmationUsesADifferentProvider

# Environment preflight (+ runs shared tests, writes swift-test.log)
bash Scripts/check-build-environment.sh --test

# Regenerate Xcode project, run tests, ad-hoc signed build; logs to XcodeProject/Logs/
bash Scripts/generate-xcode-project.sh --force --open
#   other flags: --skip-tests, --generate-only, --signed-build --team ID --app-group ID

xcodebuild -project XcodeProject/ExitIPMonitor.xcodeproj -scheme ExitIPMonitor -destination 'platform=macOS' build
open XcodeProject/DerivedData/Build/Products/Debug/ExitIPMonitor.app

# Release: add a CHANGELOG.md section, then push the tag; .github/workflows/release.yml builds,
# attests, and publishes on a clean runner. Then update the cask in jxz345/homebrew-tap.
git tag v1.0 && git push origin v1.0
bash Scripts/package-release.sh   # local test build into dist/ only
```

- Never publish release files built on this Mac. Files written here can carry this Mac's `com.apple.provenance` stamp, which the kernel won't let `xattr` remove. The stamp travels in the zip/pkg and stalls the app's launch on every other Mac. `package-release.sh` warns locally and fails in CI when a file carries extended attributes.
- When a SwiftPM build fails, the first `error:` line in `swift-test.log` is the actionable one; trailing `error: Build failed` is just a summary.
- App/widget targets need full Xcode with the macOS 26 SDK; they are not in `Package.swift`. Deployment target is macOS 14; `ExitIPControl` is `@available(macOS 26.0, *)`.
- No linter/formatter is configured.

## Source vs. generated output

`Sources/`, `Configuration/`, and `Scripts/` are authoritative. `generate-xcode-project.sh` **copies** `Sources/` and `Configuration/` into `XcodeProject/` and generates `project.yml` + `.xcodeproj` via XcodeGen. Never edit files under `XcodeProject/` (or its `DerivedData/`); edit the originals and rerun the generator with `--force` so the copies are refreshed. Target membership, embedding, entitlements, and framework links (e.g. SystemConfiguration) are defined in the generator script.

The App Group `group.com.example.exitipmonitor` is a compile-only placeholder in `Sources/ExitIPShared/AppGroupIdentifier.swift` and the entitlements; the generator's `--app-group` rewrites it in the copies only.

## Architecture

Three modules; two run as separate processes that communicate only through App Group `UserDefaults` (`ExitIPAppGroup.defaults`, keys in `ExitIPPreferenceKey`):

- **`ExitIPShared`** — compiled into every target. Models (`ExitIPSnapshot`, `CountryChange`, `ProviderID`), pure policy (`CountryChangeDetector`, `RefreshPolicy`, `CountryChangeConfirmationPolicy`), provider clients (`IPLocationProvider` implementations + `PublicIPLookupClient` in `IPLocationProvider.swift`), App Group stores (`SnapshotStore`, `IndicatorStore`, `ProviderCooldownStore`, `RefreshAttemptStore`, `AllowedIPStore`), log redaction (`LogRedactor`), and Keychain (`SecureTokenStore`). Keep testable logic here.
- **`ExitIPMonitorApp`** — menu-bar app (`LSUIElement`). `PublicIPMonitor` (`@MainActor ObservableObject`) is the central engine: owns all refresh triggers, provider rotation, confirmation, cooldowns, allowlist evaluation, and pushing WidgetKit reloads. `NetworkConfigurationObserver` wraps SystemConfiguration dynamic-store notifications (proxy/VPN/utun/interface-list changes); `RouteChangeObserver` reads the kernel `PF_ROUTE` socket for routes TUN tools install directly, filtered by the shared `RouteChangeFilter`. Any network-environment change (gateway, route, interface, proxy, DNS, TUN/VPN) must trigger a refresh. `DashboardWindowController` / `SettingsWindowController` / `AllowlistWarningWindowController` are retained AppKit windows (not SwiftUI scene routing). `RuntimeLog` writes JSON-lines to `~/Library/Application Support/ExitIPMonitor/Logs` (override with `EXIT_IP_LOG_DIRECTORY`).
- **`ExitIPMonitorWidgets`** — WidgetKit widget + macOS 26 `ControlWidgetButton`. Reads `SnapshotStore` only; **never makes network requests**. `ExitIPIntents.swift` lives in the app folder but must compile into both app and widget targets (OpenIntent requirement).

### Refresh flow invariants (enforced in `PublicIPMonitor` + shared policy; preserve them)

- All non-startup lookups respect a persisted 5-second minimum interval **per provider** (`RefreshAttemptStore`, `RefreshPolicy.providerSelection`): a request goes to the next pool provider outside its gap and is queued only when every enabled provider is inside it. Startup bypasses it once.
- Event-driven triggers go through `EventRefreshWindow` (in `handleEventTrigger`): the first event runs immediately, network-urgency events in the next 5 s merge into one `.trailing` lookup, routine events in the window are absorbed. No debounce before the first lookup.
- `LookupBudget` (shared, persisted) layers on top of that gate: each `RefreshTrigger` maps to a `RefreshUrgency` (manual / networkChange / routine). A 6-token burst bucket refills 1 every 2 min; network changes are deferred (never dropped) when it is empty, routine triggers are skipped when the result is <2 min old or no token is left, and manual is never refused. Each provider has a daily budget at 80% of its documented limit (UTC day; primary + confirmation calls), and exhausted providers are skipped by rotation. A new trigger must be assigned an urgency.
- Successful lookups advance through the enabled provider pool; transient/5xx/malformed failures may rotate to the next provider. **`429`, 401/402/403, and quota-message errors (`LookupError.pausesProvider`) never trigger failover**: the refused request is never retried on another vendor. They set a per-provider cooldown (`Retry-After` or 1 hour), and `RefreshGate` (via its `cooldowns` input) skips the paused provider in normal rotation, like an exhausted daily budget. Lookups wait (`.allProvidersPaused`) only when every enabled provider is paused or exhausted. A pause updates `status` only and never sets the error indicator, so the last verified location stays visible. Don't add rate-limit evasion.
- A country change is committed only after exactly one confirmation call to a *different* provider agrees; otherwise the last verified snapshot is kept with an "awaiting confirmation" state. Confirmation never runs after a failed primary lookup.
- Providers must return a valid ISO alpha-2 `countryCode` (use `CountryCodeResolver` when an API only gives a name) or throw; placeholders like `--` never create a country change.
- On a lookup failure (not a provider pause), country/flag are hidden on every surface until a successful lookup.
- Runtime log events (listed in README) are the way to verify behavior; give new refresh paths a `RefreshTrigger`.
- Widget reloads are requested only when rendered content changes (not timestamp-only updates).
- Allowlist is **warn-only** (network blocking was removed: it needed signing the project doesn't have). An empty list disables warnings; a fresh lookup outside the list opens the warning window once per address and shows a notice in the popover/dashboard. It never sets the error indicator or hides the location, and failed lookups never warn. Don't reintroduce network blocking.
- IPinfo Lite without a stored token is skipped by rotation (like a paused provider) unless it is the only enabled provider.

When changing shared logic, add XCTest cases in `Tests/ExitIPSharedTests/` covering persistence, refresh policy, provider error handling, and snapshot changes.

Every feature change must update `README.md` in the same change. Its **What is implemented** table must always list the complete set of features. Also update any affected usage steps, manual-check rows, and runtime-log events (see `AGENTS.md` → Documentation).
