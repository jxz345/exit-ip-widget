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

Three executable targets share portable Swift models and versioned XPC contracts:

- **`ExitIPShared`**: models, provider clients, refresh policies, storage abstractions, credential sessions and typed XPC. `FilePreferenceStorage` owns atomic daemon state; App Group defaults are used for legacy migration and personal cache data.
- **`ExitIPCore`**: `MonitoringEngine` owns lookups, quotas, confirmation, rotation, allowlist evaluation, network/route observation and IOKit system-wake observation. `RuntimeLog` compiles into the app and daemon; daemon logs are under `/Library/Logs/ExitIPMonitor`.
- **`ExitIPService`**: one root `ExitIPMonitorDaemon`, installed outside the app under `/Library/PrivilegedHelperTools`, with a system LaunchDaemon. `DaemonService` exports a typed XPC request interface; caller UID comes from the connection, never request data. Shared settings and token changes require Authorization Services rights and a matching revision. Root-only state is under `/Library/Application Support/ExitIPMonitor/Service`. The IPinfo token is explicitly stored in the System Keychain, loaded once without UI and never returned to clients.
- **`ExitIPMonitorApp`**: one UI per UID, with independent appearance, dismissals and login item. `PublicIPMonitor` is a reconnecting service client, not a lookup engine. UI activation reads state; quitting does not stop the service. Dashboard, Settings and warning controllers remain retained AppKit windows. Allowlist windows are eligible only in the active console session after a fresh successful check.
- **`ExitIPMonitorWidgets`**: widget and Control Center query the daemon with the exact Mach lookup entitlement, retaining a local outage cache. They never make provider requests. `ExitIPIntents.swift` compiles into both app and widget.
- **`ExitIPDaemon/daemon.sh`**: root service install/repair/uninstall, typed readiness verification, legacy-job migration, rollback and a fixed-command removal grant. The old `tailscale-verge.sh` remains only as a migration/reference test fixture and is not shipped.

Proxy credentials and profile files remain in each user's account. The dashboard loads proxy info once per session on a background worker. Save writes the personal 0600 YAML; Finder produces a named copy for manual import. Installers do not write profiles or change Clash Verge. Never log or commit real proxy addresses or credentials.

### Service and provider invariants

- One persistent daemon owns all monitoring. Concurrent users share the same quota, cooldowns and in-flight request. Per-user presentation is keyed by kernel UID.
- Initialize machine settings once with explicit admin authorization; a later account cannot silently replace them. Token import is separate. Shared edits reject stale revisions.
- The optional provider task verifies route, native Tailscale CLI address, interface ownership and route recheck. Candidate accounts include the previous verified owner, console user and native-client process owners. Only the fixed CLI drops privileges; commands run without a shell, with bounded time/output and process-group termination.
- The in-process loopback listener exposes read-only GET/HEAD provider/status endpoints. Preserve `TS-NATIVE`, the existing identity, profile format and 12-second freshness rejection. Bound request size, concurrency and duration. A busy port is reported and retried without stopping its owner. A stopped daemon means the endpoint is unavailable, not a separate responder serving Reject.
- Installation copies verified code to root-owned files, unloads legacy jobs and waits for workers, then checks XPC readiness. Only the root-owned manager's fixed `uninstall` command is granted without a password. Retain machine state and System Keychain credentials on uninstall/reinstall.
- Native service tests: `bash Tests/ExitIPServiceTests/run.sh`. Installer/legacy fixtures: `bash Tests/ExitIPDaemonTests/run.sh`. Fixtures do not establish live boot, login, sandboxed widget or System Keychain behavior.

### Refresh flow invariants (enforced in `MonitoringEngine` + shared policy; preserve them)

- Automatic lookups after startup respect a persisted 5-second minimum interval **per provider** (`RefreshAttemptStore`, `RefreshPolicy.providerSelection`): a request goes to the next pool provider outside its gap and is queued only when every enabled provider is inside it. Startup, the dashboard’s **Refresh now**, and provider **Test** bypass the gap and burst allowance; provider cooldowns and daily budgets still apply.
- Event-driven triggers go through `EventRefreshWindow` (in `handleEventTrigger`): the first event runs immediately, network-urgency events in the next 5 s merge into one `.trailing` lookup, routine events in the window are absorbed. No debounce before the first lookup.
- `LookupBudget` (shared, persisted) layers on top of that gate: each `RefreshTrigger` maps to a `RefreshUrgency` (manual / networkChange / routine). A 6-token burst bucket refills 1 every 2 min; genuine network changes bypass the burst gate; follow-ups are deferred when it is empty and routine triggers are skipped when the result is <2 min old or no token is left, and manual is never refused. Each provider has a daily budget at 80% of its documented limit (UTC day; primary + confirmation calls), and exhausted providers are skipped by rotation. A new trigger must be assigned an urgency.
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
