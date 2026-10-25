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

# Release (built on this Mac; no workflow): bump MARKETING_VERSION/CURRENT_PROJECT_VERSION in
# Scripts/generate-xcode-project.sh, add a CHANGELOG.md section, build, run the install matrix
# (README "Maintainer notes"), then tag, `gh release create v<version> dist/...`, update the tap.
bash Scripts/package-release.sh   # writes dist/ExitIPMonitor-<version>.{zip,pkg}, install.sh, SHA256SUMS
EXIT_IP_CASK_PATH=/opt/homebrew/Library/Taps/jxz345/homebrew-tap/Casks/exit-ip-monitor.rb bash Tests/ExitIPInstallTests/run.sh
bash Tests/ExitIPAppTests/run.sh  # compiles the real app sources: credentials and Dock icon checks
```

- Releases are built and published from this Mac with `Scripts/package-release.sh` (the user's choice since 2.0; the GitHub workflow was removed). The ZIP must have no AppleDouble entries. Files written here carry a `com.apple.provenance` stamp that `xattr` can't remove; it is harmless and did not cause the pre-startup launch stall. That stall was macOS parking its own Open Anyway approval when Use Password was chosen while loginwindow's background Touch ID request ran (lock and unlock the screen, or restart, to release it). The cask avoids it by removing quarantine after `codesign --verify`. **Read README "Maintainer notes (for the next coding session)" before touching the cask, installers, or launch behavior**: it has the log signature, the install matrix to run before any tap push, and the guardrails: keep the preflight byte-identical, never replace an older version's published assets, and revert the tap to roll back.
- When a SwiftPM build fails, the first `error:` line in `swift-test.log` is the actionable one; trailing `error: Build failed` is just a summary.
- App/widget targets need full Xcode with the macOS 26 SDK; they are not in `Package.swift`. Deployment target is macOS 14; `ExitIPControl` is `@available(macOS 26.0, *)`.
- No linter/formatter is configured.

## Source vs. generated output

`Sources/`, `Configuration/`, and `Scripts/` are authoritative. `generate-xcode-project.sh` **copies** `Sources/` and `Configuration/` into `XcodeProject/` and generates `project.yml` + `.xcodeproj` via XcodeGen. Never edit files under `XcodeProject/` (or its `DerivedData/`); edit the originals and rerun the generator with `--force` so the copies are refreshed. Target membership, embedding, entitlements, and framework links (e.g. SystemConfiguration) are defined in the generator script.

The App Group `group.com.example.exitipmonitor` is a compile-only placeholder in `Sources/ExitIPShared/AppGroupIdentifier.swift` and the entitlements; the generator's `--app-group` rewrites it in the copies only.

## Architecture

Three Swift modules; two run as separate processes that communicate only through App Group `UserDefaults` (`ExitIPAppGroup.defaults`, keys in `ExitIPPreferenceKey`). A fourth, bash module runs as LaunchDaemons:

- **`ExitIPShared`** — compiled into every target. Models (`ExitIPSnapshot`, `CountryChange`, `ProviderID`), pure policy (`CountryChangeDetector`, `RefreshPolicy`, `CountryChangeConfirmationPolicy`), provider clients (`IPLocationProvider` implementations + `PublicIPLookupClient` in `IPLocationProvider.swift`), App Group stores (`SnapshotStore`, `IndicatorStore`, `ProviderCooldownStore`, `RefreshAttemptStore`, `AllowedIPStore`), log redaction (`LogRedactor`), and Keychain (`SecureTokenStore`). Keep testable logic here.
- **`ExitIPMonitorApp`** — menu-bar app (`LSUIElement`). `PublicIPMonitor` (`@MainActor ObservableObject`) is the central engine: owns all refresh triggers, provider rotation, confirmation, cooldowns, allowlist evaluation, and pushing WidgetKit reloads. `NetworkConfigurationObserver` wraps SystemConfiguration dynamic-store notifications (proxy/VPN/utun/interface-list changes); `RouteChangeObserver` reads the kernel `PF_ROUTE` socket for routes TUN tools install directly, filtered by the shared `RouteChangeFilter`. Any network-environment change (gateway, route, interface, proxy, DNS, TUN/VPN) must trigger a refresh. `DashboardWindowController` / `SettingsWindowController` / `AllowlistWarningWindowController` are retained AppKit windows (not SwiftUI scene routing). `RuntimeLog` writes JSON-lines to `~/Library/Application Support/ExitIPMonitor/Logs` (override with `EXIT_IP_LOG_DIRECTORY`).
- **`ExitIPMonitorWidgets`** — WidgetKit widget + macOS 26 `ControlWidgetButton`. Reads `SnapshotStore` only; **never makes network requests**. `ExitIPIntents.swift` lives in the app folder but must compile into both app and widget targets (OpenIntent requirement).
- **`ExitIPDaemon`** (bash, not in `Package.swift`) — the Tailscale → Clash Verge provider, copying Sleepless's background-service methodology: `daemon.sh install|remove|status` copies `tailscale-verge.sh` to root-owned `/Library/Application Support/ExitIPMonitor/` and writes two plists. The Homebrew cask (`jxz345/homebrew-tap` `Casks/exit-ip-monitor.rb`) runs `daemon.sh install` from the bundle in its postflight (`sudo: true`, skipped while the opt-out marker exists) and removes it in its uninstall script with `sudo -n` through the grant. The app (not the daemon) keeps the full Clash Verge profile: the dashboard's proxy form saves `ClashProxySettings` to the Keychain (`ClashVergeProfile.keychainAccount`), and `maintainClashVergeProfile` renders `ClashVergeProfile.render` to `~/Library/Application Support/ExitIPMonitor/clash-verge-profile.yaml` (0600) at launch and on Save. Installers never deploy it, and nothing writes into Clash Verge. The dashboard's **Finder** (`revealClashVergeProfileCopy`) writes a 0600 copy named `Exit IP Monitor <date> (n).yaml` (`ClashVergeProfile.writeCopy`; `n` skips every name in Clash Verge's `profiles.yaml`, read via `ClashVergeProfileNaming`; one copy is kept) for the user to drag onto Clash Verge's Profiles page, which adds it as a Local profile named after the file. Clash Verge Rev 2.5.8 offers no other way to add a Local profile while it runs: `clash://install-config` only creates Remote profiles. It can't be told to activate one, and it overwrites `profiles.yaml` from memory, so don't edit its files. **Never commit or log real proxy addresses or credentials**; tests use RFC 5737 addresses and dummy values. `tailscale-verge.sh monitor` (root, KeepAlive) verifies route → Tailscale CLI → interface → route every 2 s and writes `TailscaleVerge/provider.yaml` + `state`; `tailscale-verge.sh http` runs per connection as `nobody` on the launchd-held `127.0.0.1:18766` socket (`inetdCompatibility`). The generator ships both scripts as app resources. The dashboard reads the files through `TailscaleVergeProvider`/`TailscaleVergeStatus` (shared, tested) and never contacts the daemon. Tests: `bash Tests/ExitIPDaemonTests/run.sh` (also run by `check-build-environment.sh --test` and the release workflow).

### Daemon invariants (`Sources/ExitIPDaemon`; preserve them)

- Served bytes stay identical to the reference helper (`tailscale-verge-live-v1`; header order, `Server` trailing space, 404/501 bodies), so an existing Verge profile needs no edit or reload. The one deliberate difference: `/provider.yaml` is `text/plain; charset=utf-8` so browsers show it (Mihomo's HTTP provider ignores `Content-Type`; it reads status, `ETag`, and body).
- HTTP is independent of the monitor: the responder only reads the two files, never runs a command, and serves Reject when `state` is missing, malformed, more than 12 s old (`monitor-stale`), or disagrees with `provider.yaml`.
- Only the Tailscale CLI drops privileges (`sudo -n -u '#<console uid>'`, user's groups, `env -i`); no console user (uid < 501) → `no-console-user` Reject. No new privileged surface: loopback only, fixed paths/port/intervals, no config file, no request-driven commands, no Mihomo controller calls. The only sudoers file is the removal grant `/etc/sudoers.d/exitipmonitor-tailscale-verge` (`grant_line`; `visudo -cf` before install; root:wheel 0440): literal `launchctl bootout` of both labels, `kickstart -k` of the monitor, `rm -f` of both plists and the grant, `rm -rf` of the daemon folder. Never add a command that loads, starts, or writes anything.
- `daemon.sh install` probes the port with `connect()` before loading the responder and stops whatever holds it: a launchd job's main process (XPC_SERVICE_NAME label **and** matching job pid) gets `launchctl disable` + bootout so KeepAlive/login can't restart it; anything else gets TERM then KILL; `com.apple.*` jobs and pid 1 are never touched (exit 3 if the port stays busy). Every bootout waits until `launchctl print` no longer finds the job.
- Installed on every Mac (cask postflight). A missing Tailscale or Clash Verge Rev is never a failure: the preflight report says what's missing, the monitor writes `tailscale-not-installed` without spawning anything, and the app shows `TailscaleVergeStatus.reasonText` (every reason the script writes needs plain words; `status.json` keeps codes). `daemon.sh remove` writes the opt-out marker `~/Library/Application Support/ExitIPMonitor/tailscale-verge-off` and `install` deletes it, always as the target user (`SUDO_USER`, else the console user, validated) via `sudo -n -u`, never as root.
- Test hooks (`EXITIP_TSV_*`) are honored only for an ordinary user with `EXITIP_TSV_TEST=1`, never for root or `nobody`.

### Refresh flow invariants (enforced in `PublicIPMonitor` + shared policy; preserve them)

- All non-startup lookups respect a persisted 5-second minimum interval **per provider** (`RefreshAttemptStore`, `RefreshPolicy.providerSelection`): a request goes to the next pool provider outside its gap and is queued only when every enabled provider is inside it. Startup bypasses it once.
- Event-driven triggers go through `EventRefreshWindow` (in `handleEventTrigger`): the first event runs immediately, network-urgency events in the next 5 s merge into one `.trailing` lookup, routine events in the window are absorbed. No debounce before the first lookup.
- `LookupBudget` (shared, persisted) layers on top of that gate: each `RefreshTrigger` maps to a `RefreshUrgency` (manual / networkChange / routine). A 6-token burst bucket refills 1 every 2 min; network changes are deferred (never dropped) when it is empty, routine triggers are skipped when the result is <2 min old or no token is left, and manual is never refused. Each provider has a daily budget at 80% of its documented limit (UTC day; primary + confirmation calls), and exhausted providers are skipped by rotation. A new trigger must be assigned an urgency.
- Successful lookups advance through the enabled provider pool; transient/5xx/malformed failures may rotate to the next provider. **`429`, 401/402/403, and quota-message errors (`LookupError.pausesProvider`) never trigger failover**: the refused request is never retried on another vendor. They set a per-provider cooldown (`Retry-After` or 1 hour), and `RefreshGate` (via its `cooldowns` input) skips the paused provider in normal rotation, like an exhausted daily budget. Lookups wait (`.allProvidersPaused`) only when every enabled provider is paused or exhausted. A pause updates `status` only and never sets the error indicator, so the last verified location stays visible. Don't add rate-limit evasion.
- A country change is committed only after exactly one confirmation call to a *different* provider agrees; otherwise the last verified snapshot is kept with an "awaiting confirmation" state. Confirmation never runs after a failed primary lookup.
- Providers must return a valid ISO alpha-2 `countryCode` (use `CountryCodeResolver` when an API only gives a name) or throw; placeholders like `--` never create a country change.
- On a lookup failure (not a provider pause), country/flag are hidden on every surface until a successful lookup.
- Runtime log events (listed in README) are the way to verify behavior; give new refresh paths a `RefreshTrigger`. An event that people should see in the dashboard's Event Log also needs a case in `EventLogLine.message` (shared, tested); routine records return nil. Describe the schedule only through `MonitoringRules.summary` so every surface agrees.
- Widget reloads are requested only when rendered content changes (not timestamp-only updates).
- Allowlist is **warn-only** (network blocking was removed: it needed signing the project doesn't have). An empty list disables warnings; a fresh lookup outside the list opens the warning window once per address and shows a notice in the popover/dashboard. It never sets the error indicator or hides the location, and failed lookups never warn. Don't reintroduce network blocking.
- IPinfo Lite without a stored token is skipped by rotation (like a paused provider) unless it is the only enabled provider.

When changing shared logic, add XCTest cases in `Tests/ExitIPSharedTests/` covering persistence, refresh policy, provider error handling, and snapshot changes.

Every feature change must update `README.md` in the same change. Its **What is implemented** table must always list the complete set of features. Also update any affected usage steps, manual-check rows, and runtime-log events (see `AGENTS.md` → Documentation).
