# Exit IP Monitor for macOS

A native **SwiftUI + WidgetKit** implementation kit for showing the current public exit IP's country in the macOS menu bar, plus richer details in a desktop/Notification Center widget and dashboard.

> **Platform boundary:** macOS Control Center supports third-party Control Widgets on **macOS 26+**, but Apple renders them as system-managed buttons/toggles rather than fully custom multi-line widgets. The tile can show a compact data-dense title, and at larger sizes the system shows title/value information. The richer multi-line inspection view belongs in the medium desktop/Notification Center widget and dashboard. On older macOS versions, the menu bar and WidgetKit widget remain the appropriate system surfaces.

## Install

Exit IP Monitor runs on macOS 14 or later, on Apple silicon or Intel; the Control Center control needs macOS 26. Install it with [Homebrew](https://brew.sh):

```sh
brew install --cask jxz345/tap/exit-ip-monitor
open /Applications/ExitIPMonitor.app
```

The country flag stays in the menu bar while the app runs. Click it to open or restore the dashboard directly. The dashboard is a regular window in Mission Control and App Exposé, with a Dock icon and Cmd-Tab entry while open (including when minimized). That Dock and Cmd-Tab icon is the menu-bar icon itself: the same flag, stop symbol or change highlight, updated whenever the menu bar changes. The one exception is an exit IP that isn't on your [allowlist](#exit-ip-allowlist-warning): the menu bar then shows a red stop icon next to the flag or name, and the Dock icon shows only the red stop icon. Closing the dashboard, with its close button, ⌘W or **⌘Q**, hides the Dock icon and leaves monitoring running. Quit with **Quit Exit IP** in the dashboard or the app menu's **Quit Exit IP Monitor**. Settings and Event Log do not keep the Dock icon visible. The window remembers its size and position, and recovers onto a connected display if needed. It also opens on first launch and when you reopen the running app. The cask lives in [jxz345/homebrew-tap](https://github.com/jxz345/homebrew-tap). It installs `ExitIPMonitor-<version>.zip` from this repository's [releases](https://github.com/jxz345/exit-ip-widget/releases) after checking its SHA-256.

Version **3.0 (build 14)** uses one system service and a separate menu-bar app for each user. The service starts at boot after installation and initial setup, monitors the machine even when nobody is logged in, and survives closing or quitting every menu-bar app. Each user may open Exit IP independently. Normal reopening restores that user's dashboard; a kernel-held per-user lock rejects duplicate UI processes, including development copies.

Homebrew and the package installer install the shared service with administrator authentication. If Homebrew setup is cancelled or fails, the app stays installed and shows **Install Service** or **Repair Service**; monitoring waits for a working service. A copied app or `install.sh` install needs that dashboard step. Open **Shared background monitoring → Use This Account’s Settings** once to authorize importing the configuring account's provider pool, refresh interval, allowlist, diagnostics, snapshot, quota usage, and cooldowns. Other accounts cannot overwrite initialization by opening the app. A previously enabled Tailscale → Clash Verge provider is retained during migration.

The service owns one machine-wide monitoring configuration. Every local account may view status, request a refresh, and test an enabled provider. Changes to shared settings or the IPinfo token require administrator authentication, and stale concurrent edits are rejected with the latest settings shown. Menu-bar appearance, highlight/error dismissals, warning acknowledgement, login-item preference, proxy credentials, and generated Clash Verge profiles remain personal.

The daemon reads its IPinfo token from the System Keychain once at startup, without a login-keychain prompt. Use Settings → **Import My Saved Token** to explicitly copy this account's old token, or save a new one, with administrator authentication. Clients receive token availability, never the saved value. The proxy-info form still loads its personal Keychain entry once when the dashboard opens. **Show menu-bar app at login** controls only the current user's UI; it does not control the service.

Before moving the app into place, the cask verifies its signature and removes its download quarantine. See [First launch](#first-launch). The 2.2 release remains available as the previous version.

Earlier installs stalled before startup until the Mac restarted. The cause was a macOS approval
that macOS itself had parked, not the app. A restart released the parked approval; locking and
unlocking the screen does the same within seconds. See
[installation history and root cause](#installation-history-and-root-cause).

| Task | Command |
| --- | --- |
| Update after release | `brew upgrade --cask jxz345/tap/exit-ip-monitor` |
| Reinstall the same release | `rm -f "$(brew --cache --cask jxz345/tap/exit-ip-monitor)" && brew reinstall --cask jxz345/tap/exit-ip-monitor` |
| Uninstall app and service, retaining data | `brew uninstall --cask jxz345/tap/exit-ip-monitor` |
| Uninstall and remove this account's settings/logs | `brew uninstall --zap --cask jxz345/tap/exit-ip-monitor` (machine state and System Keychain are retained) |
| Remove the service manually | `sudo /bin/bash /Applications/ExitIPMonitor.app/Contents/Resources/daemon.sh uninstall` |
| Install or repair the service | `sudo /bin/bash /Applications/ExitIPMonitor.app/Contents/Resources/daemon.sh install` |
| Inspect service status | `launchctl print system/com.example.exitipmonitor.daemon` |

To disable only Tailscale provider integration, turn off its dashboard toggle with administrator authentication. The monitoring service remains installed. The old provider opt-out marker no longer prevents installation of the required monitoring service.

3.0 service-setup renders from the actual SwiftUI view: [light](Previews/20-shared-service-light.png) and [dark](Previews/21-shared-service-dark.png). These use isolated defaults and do not install a live service.

The following screenshots describe earlier UI builds; current service and token controls are covered by the app-render test suite.

Build 5 layout references use off-screen renders of the actual SwiftUI dashboard with sample data:
[wide/light](Previews/05-dashboard-wide-light.png), [minimum-size/dark](Previews/06-dashboard-narrow-dark.png),
[installation error](Previews/07-dashboard-install-error.png), and [installation progress/dark](Previews/08-dashboard-installing-dark.png).
They verify layout, not live Mission Control or gesture behavior.
Build 7's optional-provider section is rendered from its actual SwiftUI view in
[light](Previews/09-provider-optional-light.png) and [dark](Previews/10-provider-optional-dark.png).
Build 8's explicit Keychain controls are rendered from the actual views with test credentials:
[profile/light](Previews/11-keychain-profile-light.png), [profile/dark](Previews/12-keychain-profile-dark.png),
[Settings/light](Previews/13-keychain-settings-light.png), and [Settings/dark](Previews/14-keychain-settings-dark.png).
2.0's proxy-info section is rendered from the actual view while its automatic Keychain read is
in progress, in [light](Previews/15-proxy-info-light.png) and [dark](Previews/16-proxy-info-dark.png).
The Dock icon renders come from the same `MenuBarCountryLabel` the menu bar draws:
[flag](Previews/17-dock-icon-flag.png), [country change](Previews/18-dock-icon-changed.png), and
[failed lookup](Previews/19-dock-icon-error.png).
These off-screen renders and isolated integration tests do not establish normal macOS approval.

### Clean uninstall and reinstall

Reinstall stops installed clients and the system service before replacing the app, then installs the service again. The root-owned manager stops verified copies of the installed app across logged-in users. Process identity is rechecked before TERM/KILL; unrelated apps survive. Inspection errors and respawning abort cleanup.

The installing account receives a narrow removal grant for exactly `/Library/PrivilegedHelperTools/com.example.exitipmonitor.manage uninstall`. The root-owned manager unloads the service and removes its executable, plist, public provider files, and removal grant. It retains `/Library/Application Support/ExitIPMonitor/Service/state.plist`, System Keychain credentials, personal profiles and logs. A missing grant requires the explicit administrator removal command printed by cleanup. Deleting the `.app` alone leaves the service running.

Service installation and removal share an atomic PID lock. In-place repair stages a copy of the previous executable/configuration and restores them after ordinary setup or readiness failures. An abrupt power loss can leave recovery files under `Service/install.*`; rerun repair after inspecting the reported state. Full Homebrew/package replacement removes the previous service first, so its rollback is reinstalling the prior release. Retained machine data is not deleted by reinstall or `--zap`.

Homebrew loads uninstall instructions saved when the app was installed. Updating the tap
alone cannot repair those older instructions. For the first migration, run the new helper
from an updated checkout **before** the old cask's uninstall, then install through the published tap:

```sh
bash Sources/ExitIPDiagnostics/cleanup-installation.sh --app /Applications/ExitIPMonitor.app
# Continue only after the helper reports successful cleanup.
brew uninstall --cask jxz345/tap/exit-ip-monitor
brew update
rm -f "$(brew --cache --cask jxz345/tap/exit-ip-monitor)"
brew install --cask jxz345/tap/exit-ip-monitor
```

This installation is registered with Homebrew and uses the updated hook. The cask embeds the helper for compatibility with older bundles;
`python3 Scripts/sync-homebrew-cleanup.py /path/to/Casks/exit-ip-monitor.rb` refreshes that
block without changing release URLs or checksums. Add `--check` to verify it.

The package preinstall uses cleanup helpers carried in the new package; its postinstall installs and verifies the system service before launching the app. `install.sh` uses the verified new bundle's cleanup helper, installs the app, and directs the user to **Install Service**. Failed cleanup prevents replacement.

### First launch

The release is ad-hoc signed and not notarized; notarizing needs a paid Apple Developer account.
Homebrew quarantines every download (it no longer offers `--no-quarantine`), and a quarantined
copy of an unnotarized app needs Gatekeeper's **Open Anyway** approval. Before Homebrew moves
the app into place, the cask therefore runs Sleepless's app-scoped recovery on the staged copy:
`codesign --verify --deep --strict`, then `xattr -dr com.apple.quarantine` for this app only. A
failed signature check aborts the install. The installed app then opens like a local build.
Gatekeeper still scans it, and `syspolicyd` logs `GK evaluateScanResult: 2`, but there is no
**Not Opened** dialog and no password. No Gatekeeper setting or other app is changed.

**Why the cask does this.** On macOS 27, **Open Anyway** asks for administrator authentication,
offering Touch ID and a **Use Password** button. loginwindow can have its own background Touch ID
request running; this was seen after a Touch ID unlock on a Mac with a second account.
Choosing **Use Password** then lets that request take Touch ID back and cancel the approval
(`coreauthd`: "Canceled by another authentication"). The password dialog stays open and accepts
the password, but macOS discards the result and parks the approval. While it is parked, every
launch of the app from that path waits before startup, quarantined or not. `syspolicyd` logs
"waiting on another evaluation", and the 96 KB process samples at `_dyld_start + 0`. macOS
retries the parked approval only when loginwindow's request ends: at the next screen unlock, a
logout or restart, or another Touch ID use. That is why a restart appeared to fix the stall.

The package and copied apps still need **Open Anyway**, and a leftover parked approval can still
block any install route. If an app waits before startup after an approval:

1. Lock the screen (**Control-Command-Q**) and unlock it. Within seconds `syspolicyd` logs
   `Allowing code due to user override` and the waiting app starts, with no relaunch. A restart
   also works.
2. When you approve with **Open Anyway**, authenticate with **Touch ID** instead of **Use
   Password**. In testing, Touch ID completed the approval at once even with loginwindow's
   request running.

Removing quarantine, Sleepless's manual recovery, does not release a parked approval. In
testing, the copy without quarantine still waited until step 1. To check for a parked approval
(read-only; in zsh `log` is a builtin, so use `/usr/bin/log`):

```sh
/usr/bin/log show --last 2h --style compact --predicate 'process == "syspolicyd" AND (eventMessage CONTAINS "Getting auth to allow override" OR eventMessage CONTAINS "Allowing code due to user override")'
```

A `Getting auth to allow override` line with no later `Allowing code due to user override` means
an approval is still parked.

A `com.apple.provenance` attribute is not evidence that a build came from another Mac.
macOS creates it locally during Gatekeeper evaluation, and it played no part in the stall.
Historical build 6 used GitHub Actions; the replacement build 8 is built and tested locally
without Actions. Verify the download checksum and signature to identify the installed build.
Do not delete security databases or disable Gatekeeper to diagnose launch problems.

### Launch diagnostics

The installer checks a live response from the app's main thread, its bundle path, PID,
version, and build (including a macOS App Translocation copy with the same verified signature). Merely appearing in Activity Monitor is not success. To trace approval and verify launch:

```sh
/bin/bash /Applications/ExitIPMonitor.app/Contents/Resources/diagnose-launch.sh --trace --launch --timeout 180
```

Omit `--launch` to inspect the existing process without opening another copy. From a source
checkout use `bash Scripts/check-launch.sh`. `--app PATH` selects another bundle and
`--output DIR` selects a new or empty diagnostic directory (an existing report is rejected). A successful check exits 0; a failed signature
or missing/stale readiness response exits 1; invalid arguments exit 2. Cancellation exits 130 (Ctrl-C) or 143 (termination).

Build 6's `--trace` starts an external information-level security log collector **before**
requesting launch. It works through `/bin/bash` even when application code never runs.
`security-stream.txt` and `security-history.txt` contain Gatekeeper and authentication-service
messages within the capture window, including approval results without the app name.
`identity.txt` records both architectures' code identities; `summary.txt` distinguishes
verified readiness, pre-entry blockage, startup without readiness, and inconclusive failure.
`incomplete.txt` identifies unavailable or truncated evidence, including permission errors.
Collectors stop on success, failure, timeout, or cancellation; collection commands have deadlines
and trace log files have size limits. Without `--trace`, the normal readiness check remains available.
The 180-second wait allows time for manual approval; it is not a claim that approval will succeed.

The checkout's trace also captures a matching process after five seconds without readiness,
so interrupting a long wait retains useful evidence. Cancellation preserves that early sample,
or attempts one bounded sample if none exists. The summary keeps `result=cancelled` separate
from `startup_observation`; an observed pre-entry stack does not turn cancellation into a
completed launch test. `evaluation_observation=waiting_on_other_evaluation` records an
app-associated macOS log message, not a proven cause. Sampling permission errors are reported
as incomplete evidence. A wait with missing or redacted bundle identity is reported as
`unattributed_wait_observed`, without assigning it to this app. These diagnostics can run from the checkout against an unchanged
installed bundle; no rebuild or reinstall is needed to compare launch locations.

Each check prints its progress and local output directory under
`~/Library/Application Support/ExitIPMonitor/Logs/launch-check-*`. On failure it saves bounded
signature, attribute, app-specific security-log and process-sample checks. A sample stuck at
`_dyld_start + 0` means execution has not reached app startup. A startup record without
`app_ready` identifies the last completed app stage. The main thread refreshes its readiness
record every two seconds; a record more than eight seconds old is rejected.

`blocked_before_entry` after an **Open Anyway** approval usually means macOS parked that
approval (see [First launch](#first-launch)). Lock the screen and unlock it; the checker in
the next build prints that hint with the blocked-process error.

The release installer saves `install-*` in the same Logs folder. Root daemon setup saves
`/Library/Logs/ExitIPMonitor/daemon-install-*` and removal saves `daemon-remove-*`.
Step logs include UTC time, duration, timeout and exit status. These diagnostics stay local;
they exclude Keychain values and proxy configuration. Trace reports retain Apple's default privacy redaction but may include unrelated authentication events within the short capture window. Review their contents and local paths before sharing them.
The launch checker never changes quarantine, signatures, or system security settings.

If macOS says the app **is damaged and can't be opened**, the copy predates the current release and has only a partial signature. Install the current release.

### Installation history and root cause

Verified on **2026-10-19**: replacing the stalled build 1.0 (2) with the GitHub-built
**1.0 (3)** resolved the observed launch failure. The published ZIP passed checksum and
GitHub build-attestation verification, and the app installed through Homebrew matched that
ZIP byte-for-byte. Its first checked launch reached readiness in about six seconds; a
restart reached readiness in about two seconds. Both completed an IP lookup, and quarantine
remained intact. The user also confirmed that installation succeeded.

The stalled build 1.0 (2) matched its published ZIP byte-for-byte and passed strict signature
verification. Its stalled process had a 96 KB footprint and sampled only `_dyld_start + 0`;
no application startup code had executed. The daemon was healthy. macOS security logs showed
an approval/authentication request without a completion in the captured interval, and a
local provenance write. These observations locate the failure before app startup; they do
not prove a damaged download, an extension fault, or a universal-binary fault.

A fresh build with the same signing policy, both architectures and the widget extension
passed normal **Open Anyway** approval with quarantine retained. The app reached readiness
and completed an IP lookup. The checker also handles App Translocation after validating
that the running copy has the installed app's code identity and a valid sealed bundle.
The successful fresh build did not establish the cause of the earlier stall. Diagnostics
expose a recurrence instead of reporting a suspended process as a successful launch.

On **2026-10-19**, build **1.0 (5)** also ran successfully from `/Applications`, then stalled
following a Homebrew uninstall/install and **Open Anyway** with administrator-password
approval. Its installed files matched the release ZIP and passed signature verification.
The process again had a 96 KB footprint at `_dyld_start + 0`, with no startup heartbeat.
Expanded information-level logs showed **Allow Override**, **Waiting for user override
authentication**, and `coreauthd` reporting **Unable to get the SessionAgent endpoint**;
no completion appeared in the captured interval. This locates a pending authentication
handoff but does not prove the endpoint error caused the stall. Signing, packaging, and
the launch-check scripts were unchanged between builds 3 and 5. Build 6 adds external tracing;
it does not claim a fix. Successful reopening and another reinstall must be checked separately.

Local build **1.0 (7)** was installed on **2026-10-19** after verified removal of the old
provider and Homebrew installation. The app's signature passed, but launch again stopped at
`_dyld_start + 0` without a startup heartbeat; the external trace reported
`blocked_before_entry`. Security logs showed an evaluation waiting on another evaluation.
The new cleanup helper terminated that real stalled process and verified that both provider
services, workers, files and the removal grant were absent. Build 7 fixes cleanup and app-only
installation; it did not resolve the macOS launch failure. It was installed as a
standalone app, stopped and without a provider before the build 8 Homebrew test. The section previews above are off-screen
renders, not evidence of a successful live launch.

Further comparison on the same boot confirmed that the unchanged build 7 reached readiness
and completed an IP lookup from its Xcode Release directory. Its early sample showed a
separate main-thread wait in `SecItemCopyMatching` during startup profile maintenance;
readiness took about 43 seconds after app entry. The byte-identical `/Applications` copy
remained before app entry through both normal launch and direct execution. An administrator
captured a read-only `syspolicyd` sample: its approval-response handler and evaluation-completion
queue were waiting, and its LocalAuthentication client was waiting for a synchronous reply.
Earlier authentication logs recorded the corresponding approval request being stashed.
Together these observations support an unfinished macOS approval/authentication handoff;
they do not establish why it stopped completing. The controlled reboot comparison was
skipped in favor of testing build 8 directly through the published Homebrew tap. Build 8
removes automatic Keychain access; that change does not establish a fix for the separate
macOS pre-entry approval stall. Normal installed-app launch and reinstall are separate
acceptance checks.

The replacement **v1.0 / build 8** was published locally without GitHub Actions on
**2026-10-19** and installed from the GitHub release through the published Homebrew cask.
All 17 installed bundle files matched the validated app, both architectures passed strict
signature verification, and quarantine remained intact. No provider service, provider files,
or removal grant were installed.

The first launch and a normal launch after the user completed approval both reported
`blocked_before_entry`: a 96 KB process at `_dyld_start`, with no application readiness.
At the time of the password dialog, `syspolicyd` recorded **Allow Override**, **Getting auth
to allow override**, and **Waiting for user override authentication**. This is macOS
Gatekeeper approval authentication. App-only installation does not guarantee a password-free
macOS approval; the app's own administrator operation remains behind **Install Provider**.
The trace also recorded LocalAuthentication endpoint errors, without proving their cause.

A real `brew reinstall` then exercised the hung process: Homebrew's normal Quit failed,
the embedded cleanup helper terminated the verified process with TERM, verified provider
absence, and allowed installation to finish. The reinstalled bundle again matched all 17
files and retained quarantine; existing profile and preference file hashes were unchanged.
The app was left installed and stopped with no provider. Homebrew lifecycle acceptance passed;
live launch, dashboard, and monitoring acceptance remain blocked by the pre-entry stall.

**Root cause, established 2026-10-20.** The affected Mac's unified log recorded seven
**Open Anyway** approvals in four days, all with **Use Password**:
- Six started while loginwindow's background Touch ID request was running (`coreauthd`:
  `replaced: <… pid:409 …>`). In each, **Use Password** let that request resume and cancel the
  approval ("Canceled by another authentication").
- Those approvals stayed parked for 26–69 minutes, until a screen unlock, restart, or other
  Touch ID use. That end was logged as `retrying request`, then `Allowing code due to user
  override`.
- The one approval that started without that request completed instantly.

The build 7 `/Applications` copy above had no quarantine and still stalled, because an approval
for that path was parked; its Release-directory copy used another path and ran. This accounts
for every pre-entry stall recorded above, including the "SessionAgent endpoint", stashed
request and "waiting on another evaluation" observations. No app code ran in any of them.

Live trials the same night, each starting from a fresh first-launch prompt. The second and
third used new bundle identities in new folders, because Gatekeeper skips an identity that
has been approved and has run:
- **Approval with Use Password** parked as predicted. Sleepless's manual recovery (quit, verify,
  `xattr -dr com.apple.quarantine`, open) still waited at `_dyld_start`. Lock and unlock released
  it in about two seconds: the waiting process started, reached readiness and completed a lookup.
- **Approval with Touch ID** completed in about two seconds, with loginwindow's request running.
- **The cask's preflight steps** left no quarantine on the installed app. It opened with no dialog
  or password (`GK evaluateScanResult: 2`), reached readiness within a second, and did the same
  after a reinstall.

The published cask now uses the third approach; build 8's ZIP and checksum are unchanged.

The implementation follows Sleepless's ad-hoc signing and Homebrew service implementation.
Sleepless's cask leaves quarantine removal to the user as a recovery; this cask applies the
same app-scoped commands before the first launch. Provider setup is explicitly deferred to the
dashboard. The launch diagnostics replace the old `pgrep` success check with a fresh
main-thread heartbeat tied to the installed build, add startup milestones, and put deadlines and
timestamped logs around installer and daemon commands. The fix needed no change to the app, the
widget, or the architectures, and provenance metadata was not involved.

### Without Homebrew

Each [release](https://github.com/jxz345/exit-ip-widget/releases) also has an Installer package, an install script, and `SHA256SUMS`. Check downloads with `shasum -a 256 -c SHA256SUMS`.

- **`ExitIPMonitor-<version>.pkg`:** double-click it and click **Done** at the "can't verify" warning. Then click **Open Anyway** in **System Settings → Privacy & Security**, authenticate with Touch ID, and enter your password in Installer. If Installer doesn't open after **Open Anyway**, lock the screen and unlock it ([why](#first-launch)).
  - The package is unsigned, because signing one needs a Developer ID Installer certificate.
  - It installs to `/Applications`, verifies app and provider cleanup first, and launches the new app afterwards.
  - Installer doesn't quarantine what it installs, so the app needs no second approval.
  - The package is not relocatable, so it never updates a copy elsewhere. It allows Apple silicon and Intel without asking for Rosetta.
- **`install.sh`**, for when the package's approval doesn't work. Run:

  ```sh
  curl -fsSL https://github.com/jxz345/exit-ip-widget/releases/latest/download/install.sh | bash
  ```

  The script:
  - downloads the package with `curl`, which adds no quarantine, and checks its SHA-256 and the app's signature;
  - stops the old app, verifies provider removal, and aborts if cleanup fails;
  - installs to `/Applications`, or to `~/Applications` if `/Applications` isn't writable;
  - launches the app and waits up to 60 seconds for a fresh main-thread readiness response.

  With the package already in Downloads, `bash ~/Downloads/install.sh` uses the newest matching `ExitIPMonitor-<version>*.pkg` there instead; browsers save repeat downloads as `… (1).pkg`. Run it with `bash`, because a quarantined script run directly can be blocked. If replacing the app fails with **Operation not permitted**, allow the terminal under **App Management**. If the app does not become ready, it exits with an error and prints the directory containing bounded launch diagnostics.
- **A copied app**, for example one sent by AirDrop, is quarantined. Use the current release and approve it with **Open Anyway**, authenticating with Touch ID. If it then waits before startup, lock and unlock the screen ([why](#first-launch)). Run the launch check above.

### Widgets and signing

The widget and Control Center query the daemon through the same versioned XPC interface as the app, using a narrow Mach-service lookup entitlement. They do not need shared-container access to read machine state and never perform IP lookups themselves. During a service outage they mark their local cache stale and hide the location behind the unavailable indicator.

The release is ad-hoc signed. Widget discovery, Control Center registration, boot/login behavior, and downloaded-app approval must still be checked on the target macOS release; compilation and an isolated XPC test do not establish those system integration outcomes. Team-signed builds may keep a registered App Group for legacy migration and widget cache storage.

## Liquid Glass conformance

The implementation follows Apple’s Liquid Glass guidance for macOS 26+ without forcing a visual effect into the content layer:

- **Standard system controls first:** the native `NSStatusItem` and dashboard window, plus SwiftUI `Form`, `GroupBox`, `Button`, `Picker`, `Toggle`, `WidgetKit`, and `ControlWidgetButton`, follow platform appearance and accessibility settings.
- **No imitation glass:** The dashboard’s former custom-colored details card is now a standard `GroupBox`. The code deliberately avoids applying `glassEffect` to content cards, because Apple reserves Liquid Glass for the functional controls/navigation layer and recommends standard materials within content.
- **Meaningful color only:** yellow remains limited to the confirmed country-change status. System semantic colors provide the rest of the hierarchy, preserving legibility in light mode, dark mode, Increased Contrast, and Reduce Transparency.
- **Accessibility-friendly behavior:** the app uses native controls and avoids custom motion, so system Reduce Motion and transparency settings remain authoritative. Validate the finished Xcode build with those settings enabled before release.

## What is implemented

| Surface | Behavior |
| --- | --- |
| **Boot service and IPC** | One `com.example.exitipmonitor.daemon` system LaunchDaemon, restart-on-failure, root-owned atomic state, versioned typed XPC requests, kernel-derived caller UID, per-user presentation, administrator rights for shared changes and revision conflicts. Clients reconnect automatically; protocol mismatch and outages are visible. The service starts at boot and needs no open UI after initial setup. |
| **Migration** | Explicit first-account settings/snapshot/budget/cooldown import, separate token import, no later automatic overwrite, legacy optional-provider enablement preserved, and legacy jobs unloaded. Appearance imports once per UID; widgets cannot seed another account’s settings. |
| **Menu bar** | Defaults to the compact **color flag**. Settings offers **country name**, **country code**, **color flag**, or **flag + country name**. It shows no IP or provider information in the resting state. |
| **Single instance per user** | Each macOS account may run one independent menu-bar client. Normal reopening restores that user’s dashboard; an atomic per-user process lock rejects duplicate clients and releases on exit or crash. All clients share one root-owned daemon, one lookup schedule and one budget. |
| **Change attention** | A country change is first confirmed by a **different documented API**. Only then does it trigger a change dot, bold label, accessible announcement, and a visible yellow **dashboard and widget** banner for **10 minutes**. The menu-bar label retains its country-change emphasis; the dashboard and widget show a yellow notice. The person can dismiss the current alert or permanently turn off future highlights in the dashboard or Settings. Changing IP while keeping the same country does not trigger the alert. |
| **Error state** | A failed lookup shows a clear error and hides country name/flag across the menu bar, dashboard, widget, and Control Center, showing a **red stop icon** (`xmark.octagon.fill`) where the flag would be: the menu bar and Dock show the red icon (with "Exit IP error" for the text styles), the dashboard header shows it in red, and the widget and Control Center use it too. Control Center keeps the triangle only for a confirmed country change. **Clear error** removes the message but keeps location hidden until a successful lookup restores it. Provider country codes are validated or resolved from a known country name before a snapshot is stored. |
| **Desktop / Notification Center widget** | Small: flag, country code/name, age. **Medium (recommended for quick inspection):** country, IP, city/region when supplied, organization, relative update time, stale marker, and country-change banner — all without opening the app. |
| **Control Center (macOS 26+)** | A resizable `ControlWidgetButton` shows a compact title in the form **`JP · 203.0.113.8 · 1:45 PM`** (with ` · stale` appended when the data is older than twice the refresh interval) plus an alert symbol after a confirmed country change or while the location is hidden by an error. Resize the tile in Control Center for the system to expose more title/value space. Tapping opens the dashboard, but the country code, current public IP, and last-update time are visible without opening it. |
| **Dashboard window** | The persistent menu-bar flag opens the single retained dashboard directly. A normal titled, resizable primary window participates in Mission Control, App Exposé, Cmd-Tab, full screen, and window cycling. The Dock icon remains while the dashboard is open or minimized and disappears when it closes, even if Settings or Event Log remain open; monitoring continues. That Dock and Cmd-Tab icon is the menu-bar label itself (`DockIconController` renders the same `MenuBarCountryLabel` at the same moment): the flag or chosen text style, the stale prefix, the red stop symbol after a failed lookup, and the country-change highlight. While the exit IP is outside the allowlist, the menu bar adds a red stop icon beside the flag or name and the Dock icon is only that red stop icon. It is re-rendered only when what it shows changes, colored for the system appearance. Reopening brings the same window onto the active desktop, restores its remembered frame, and repeats focus after the Dock transition; disconnected displays are handled. Default size is 1000 × 860, clamped to the display. Two columns become one below 960 points, preserving unsaved profile edits; content scrolls and the footer stays available. The left column contains current exit IP, country, location, network, timezone, update time/age, source, the allowlist, and the Clash Verge profile editor. The right contains Monitoring, provider setup/status, and Apply in Clash Verge. Profile fields use full-width label/value rows. Buttons use consistent native regular sizing, minimum widths, and equal widths for paired actions; icon-only removal controls have accessible labels and tooltips. File/URL rows show a single truncated value with its full tooltip and aligned actions beneath. Monitoring shows schedule, highlights, provider order/health/daily budgets, login control, Edit in Settings, and Event Log. Event Log shows the last 500 important UTC-stamped events, updates live, and offers Copy All and Show Log Files. Missing Clash Verge has an installation note; installed Clash Verge has one **Open Clash Verge** action, next to the steps in Apply in Clash Verge. The proxy-info buttons **Load proxy info**, **Save** and **Remove** share one row. The profile file's **Finder** shows a copy named `Exit IP Monitor <date> (n).yaml`, with the note **Need to manually apply the profile in Clash Verge Rev** beneath. Stale data, country changes, and errors remain visible, with Refresh now, Dismiss, Turn Off Highlights, and Clear error actions. The footer offers Settings, Clear indicators, Quit Exit IP, and monitoring status. |
| **Menu-bar interaction** | The status item remains present with or without windows and updates its flag/name, error symbol, stale marker, and country-change highlight. Clicking opens the dashboard without a popup. Standard app menus provide Settings (Cmd-,), Close Window (Cmd-W), Dashboard (Cmd-1), Minimize (Cmd-M), editing commands, and Quit Exit IP Monitor (no shortcut). **Cmd-Q closes the app's windows instead of quitting**, so the menu-bar app remains available. The daemon also continues after an explicit Quit. Quit Apple Events (Homebrew, logout, `osascript`) still quit. |
| **Dashboard daemon installation** | The Shared background monitoring section shows connection/setup state, Install or Repair, and an explicit one-time **Use This Account’s Settings** import. Native macOS authentication runs the bundled installer off the main thread; success requires a matching XPC readiness response. Cancellation/failure remains visible and retryable. Monitoring requires the service; profile editing remains personal and available. |
| **Installation diagnostics** | Checksum and strict signature verification, timestamped installer and daemon logs, main-thread launch readiness with PID/path/build validation, bounded command execution, and process samples. Optional external `--trace` starts before launch and records Gatekeeper/authentication decisions at information level, code identities, startup records, a concise result summary and incomplete-evidence notices. Early samples survive cancellation; startup observations and app-associated pending evaluations are reported separately from the command result. Collectors stop on every exit path. A blocked-before-entry result also names the recovery for an approval macOS parked: lock and unlock the screen. External cleanup logs record process termination and verified provider removal before uninstall/reinstall; cleanup failures abort replacement. |
| **Settings window** | Menu-bar style and country highlights are personal. Provider pool/start provider, refresh frequency, allowlist, diagnostics and System Keychain IPinfo token are machine-wide and require administrator authentication to edit. Test checks an enabled provider against the shared quota/cooldown. IPinfo controls offer **Import My Saved Token**, **Save token**, and **Remove token**. Debug simulations affect the local UI only. **Show menu-bar app at login** is per-account. |
| **Exit-IP allowlist warning** | The dashboard holds exact IPv4/IPv6 addresses you expect to exit from (empty list = no warnings). When a fresh, successful lookup returns an address outside the list, an **Exit IP Not Allowed** warning window opens once per event in the active console session, independently acknowledged per user, and the dashboard shows an orange **Exit IP not on the allowlist** notice. While the address stays outside the list, the menu bar shows a red stop icon (`xmark.octagon.fill`) next to the flag or country name, and the Dock and Cmd-Tab icon shows only the red stop icon. The app **only warns**: it never blocks or changes networking, and the menu bar keeps showing the country. Failed lookups never warn. See [allowlist details](#exit-ip-allowlist-warning). |
| **Tailscale → Clash Verge provider (root daemon)** | Optional integration inside the single native service. It verifies the routed Tailscale utun and CLI address, writes the existing provider/state files and serves bounded read-only HTTP on `127.0.0.1:18766`. It retains `TS-NATIVE`, YAML/status endpoints and freshness rejection. Candidate users include the last verified Tailscale owner, console user and native-client process owners. A busy port is reported and retried without stopping its owner. No second daemon or per-request responder is installed. Proxy profiles and their Keychain entry stay in each user’s account; file actions and manual Clash Verge import remain available. |
| **Refresh engine** | One daemon owns network/route and system-wake observation, startup lookup, 15-minute default timer, country confirmation, provider rotation/health, persisted snapshot, quota usage and cooldowns. UI launch/activation only reads state. Concurrent refresh requests share the in-flight lookup. Network events retain immediate-plus-trailing checks and the existing daily/burst/spacing policies. The service uses its System Keychain token at startup. Quitting a UI or logging out does not stop monitoring. |
| **Release packaging (install on another Mac)** | Builds a universal Release app, embedded native daemon and widget, signs inside-out, checks signatures/architectures, and emits ZIP, package, install script, SHA256SUMS and an exact-version Homebrew cask. Homebrew/package setup installs the required service; copied/script installs use dashboard setup. Root executable and launchd plist are outside user-writable bundles. Legacy two-job cleanup, retained-state reinstall and ordinary repair rollback are supported. Publishing remains a separate action. |
| **Keychain access** | The daemon reads the shared IPinfo token from the System Keychain without user interaction; an owner-UID ACL permits root and survives ad-hoc code-hash changes. Only administrator-authorized set/remove operations can modify it. State responses contain availability and errors, never the saved secret. Explicit import reads this account’s previous token. Proxy information remains in the user Keychain and loads on a serial worker once when the dashboard opens; explicit Load/Save/Remove remain available. |
| **Privacy and resilience** | The selected provider sees the public IP address. Provider credentials are kept in the macOS Keychain; the widget receives only the non-secret snapshot through XPC. |

## Exit-IP allowlist warning

The dashboard can hold a list of exact IPv4 or IPv6 addresses you expect your
traffic to exit from. An empty list turns warnings off.

After a fresh, successful lookup returns an address outside the list (or the
list is edited so the current address is no longer included), the app:

- opens an **Exit IP Not Allowed** warning window showing the address, once per event for the active console user (refreshing with the same address does not reopen it); its **Open
  Dashboard** button goes straight to the list;
- shows an orange **Exit IP not on the allowlist** notice in the
  dashboard for as long as the address stays outside the list;
- for as long as the address stays outside the list, shows a red stop icon
  next to the flag or country name in the menu bar, and only the red stop icon
  as the Dock and Cmd-Tab icon.

The app **only warns**. It never blocks traffic, edits routes or firewall rules,
or installs a network extension, so it needs no special signing. The warning is
not an exit-IP error: the menu bar, widget, and Control Center keep showing the
verified country (the widget and Control Center show no allowlist state). Adding
the current address, emptying the list, or a later lookup that returns an
allowed address closes the window and removes the notice and the red stop icon.
A failed lookup or disconnected service never opens a warning. The allowlist is shared and administrator-controlled; each user acknowledges warning events separately.

## Tailscale → Clash Verge provider (root daemon)

Clash Verge Rev in TUN mode next to the native Tailscale client must send MagicDNS
(`+.ts.net`, answered by `100.100.100.100`) out through Tailscale's own `utunN`.
macOS can renumber that tunnel when Tailscale reconnects, and a profile that names
the interface then breaks until it is edited and reloaded. This optional daemon
keeps one Mihomo proxy-provider member, `TS-NATIVE`, bound to the current, verified
Tailscale interface. Mihomo polls it every 3 seconds, so reconnects are picked up
with the same core and no reload. The rest of the app works the same without it.

The integration runs inside `ExitIPMonitorDaemon`, alongside public-IP monitoring. Enable it with the dashboard toggle after service setup. It retains the provider URL and profile format from earlier releases.

- A native task verifies a non-default route to `100.100.100.100`, a single CGNAT IPv4 address from the native Tailscale CLI, an UP utun owning that address, and the same route on recheck. A pass is bounded to about seven seconds, individual commands to two seconds, output to 64 KiB. Timeout terminates the command process group. Successful passes are followed by a two-second pause.
- The CLI runs without a shell as an eligible user, trying the last verified owner, console account, and other native Tailscale process owners. With no verifiable client, the provider rejects. Fast User Switching does not automatically discard a still-valid Tailscale owner.
- The in-process listener binds only `127.0.0.1:18766`. It allows GET/HEAD of `/provider.yaml` and `/status.json`, limits requests to 8 KiB, concurrent connections to 32 and incomplete clients to three seconds. It exposes no configuration or credential operations. Checks older than 12 seconds yield Reject. A busy port is reported and retried every five seconds; its owner is left running.
- Public compatibility files remain in `/Library/Application Support/ExitIPMonitor/TailscaleVerge/`. They contain the provider interface/reason, not machine credentials or private settings. XPC supplies dashboard status; clients do not poll these files.

`provider.yaml` keeps the `TS-NATIVE` member and `udp: true`, with inline `text/plain` responses. `status.json` keeps the existing identity and fields. If the entire daemon stops, the endpoint is unavailable; Mihomo may retain its previous member until the service returns. This is not a kill switch.

### Install, disable, and rollback

Install from a **built application bundle**, not the source script directory:

```bash
sudo /bin/bash /Applications/ExitIPMonitor.app/Contents/Resources/daemon.sh install
launchctl print system/com.example.exitipmonitor.daemon
sudo /bin/bash /Applications/ExitIPMonitor.app/Contents/Resources/daemon.sh uninstall
```

Installation verifies the signed bundle, copies the executable to `/Library/PrivilegedHelperTools/com.example.exitipmonitor.daemon`, installs `/Library/LaunchDaemons/com.example.exitipmonitor.daemon.plist`, registers the administrator configuration right, and verifies a matching XPC response. It removes the legacy `tailscale-verge` and `tailscale-verge-http` jobs and their old broad removal grant. Launchd never executes the daemon from a user-writable app bundle.

The new removal grant authorizes only the root-owned manager's fixed `uninstall` command. Uninstall retains shared state and credentials; reinstall reuses them. Disable just the optional integration through its dashboard toggle. An in-place repair keeps an executable/plist backup until readiness succeeds; reinstalling an older released app is the release rollback. See [Clean uninstall and reinstall](#clean-uninstall-and-reinstall).

### Missing Clash Verge profile and provider controls

The following describes earlier UI fixes. In 3.0 the shared background service is required and the separate Tailscale provider toggle is optional.

Build 1.0 (3) hid **Clash Verge profile**, **Apply in Clash Verge**, and **Tailscale → Clash
Verge provider** when the monitor's LaunchDaemon plist was absent. The features were still
in the app, but that visibility rule made incomplete setup look like removed functionality.

Starting with **1.0 (4)**, all three sections remain visible. An absent daemon shows
**Background provider is not installed** and **Install Provider** in the dashboard. A
partial install shows **Background provider setup is incomplete**. Saved profile editing
remains available, with a reminder to install the provider before using Tailscale routing.

Click **Install Provider**, then complete the native macOS administrator authentication
prompt (the same mechanism Sleepless uses). Setup runs off the main thread, shows progress,
and verifies that both background services are loaded before reporting success. Cancellation
is shown explicitly; a failure shows **Retry Installation**. The dashboard updates without restarting the app.
The app never asks for or stores the administrator password itself.

A Homebrew install or reinstall sets the provider up with one password prompt. If that prompt
was cancelled, setup failed, or the opt-out marker exists, the dashboard shows **Install
Provider**. The package and shell installers don't set it up. Cancelling dashboard
authentication leaves the app usable and permits retry.
See [Clean uninstall and reinstall](#clean-uninstall-and-reinstall) for old cached cask hooks.

Restore and check the daemon from Terminal:

```sh
sudo /bin/bash /Applications/ExitIPMonitor.app/Contents/Resources/daemon.sh install
/bin/bash /Applications/ExitIPMonitor.app/Contents/Resources/daemon.sh status
```

Enter the Mac administrator password in Terminal. A successful install prints **Service
installation complete**, and `status` lists both jobs as **loaded**. Build 4 refreshes the
dashboard automatically; quit and reopen older builds. If setup fails, inspect the diagnostic
path printed by the command under `/Library/Logs/ExitIPMonitor`. Dashboard installation also
saves its result in `~/Library/Application Support/ExitIPMonitor/Logs/daemon-setup-*.log`.

A normal reinstall does not delete the saved proxy credentials or
`~/Library/Application Support/ExitIPMonitor/clash-verge-profile.yaml`. Missing dashboard
sections in an older build therefore do not mean the profile was removed; avoid `brew uninstall --zap` when
preserving settings. Restoring the daemon needs administrator authentication, separately
from the app's Gatekeeper approval.

### Reasons

`status.json` and the unified log report a reason code; the dashboard and the Event
Log show it in plain words (`TailscaleVergeStatus.reasonText`):

| Code | Shown as |
| --- | --- |
| `verified` | Direct on `utunN` |
| `tailscale-not-installed` | Tailscale isn't installed |
| `tailscale-cli-unavailable` | Tailscale isn't running or is logged out |
| `tailscale-cli-timeout` | Tailscale didn't answer in time |
| `no-tailscale-route` | Tailscale isn't connected |
| `no-tailscale-ip` | Tailscale has no IPv4 address yet |
| `no-console-user` | Nobody is logged in |
| `interface-not-owned-by-tailscale` | That tunnel isn't Tailscale's |
| `route-changed-during-check` | The route changed during the check |
| `route-timeout`, `interface-timeout`, `route-recheck-timeout` | A check timed out |
| `route-unavailable`, `interface-unavailable`, `route-recheck-unavailable` | A check failed |
| `monitor-stale` | The monitor stopped updating |
| `monitor-error` | The monitor's state can't be read |
| `invalid-interface` | The reported tunnel is invalid |
| `starting` | Starting up |

Without Tailscale, the monitor only tests for the CLI every 2 seconds; it runs no
`route`, `ifconfig`, or `sudo`.

### Verge profile

Clash Verge runs one profile at a time (a local file or a URL). The provider URL is
not a profile: it goes **inside** that one profile, as a `proxy-providers` entry, and
Mihomo fetches it from there every 3 seconds.

**The app's full profile.** The dashboard's **Clash
Verge profile** group is available even without the daemon and asks for your proxy: name, type (SOCKS5 or HTTP), server, port,
username, and password: the **proxy info**. **Save** stores it in the macOS Keychain, as one entry (account
`clash-verge-proxy`). It writes a complete Clash Verge profile to
`~/Library/Application Support/ExitIPMonitor/clash-verge-profile.yaml`, with mode
0600: readable only by you, which includes Clash Verge, since it runs as you. The
profile contains:

- the settings, TUN, and DNS of the verified profile, including the `+.ts.net` →
  `TS-DIRECT` policy (the controller `secret:` is left out; Clash Verge supplies its own);
- your proxy with `udp: true`;
- the `tailscale-live` provider below, with `udp: true` on its `TS-NATIVE` payload;
- the `Proxy` group (your proxy) and `TS-DIRECT` group;
- the rules: Tailscale ranges, processes, and domains; private ranges; `MATCH,Proxy`.

Opening the dashboard reads the proxy info from the Keychain once per app session, in the
background, fills the form, and brings the file up to date with the current template.
**Load proxy info** reads it again. Only a successful load or **Save** updates the file;
startup and automatic refresh do not access Keychain. Failed reads leave the existing file
unchanged. The app never logs the proxy. Neither
the app nor `daemon.sh` puts anything into Clash Verge.

**The copy to drag in.** Clash Verge Rev adds a file dropped on its **Profiles** page
as a **Local** profile named after the file, `.yaml` included (**New** → **Local** →
**Choose File** names it the same way). So the profile file's **Finder** button:

- reads the profile names in Clash Verge's
  `~/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev/profiles.yaml`
  (read only; a missing or unreadable list counts as empty);
- copies the profile file to `Exit IP Monitor <yyyy-MM-dd> (n).yaml` in the same folder,
  mode 0600. The date is today's local date, and `n` is the lowest number whose name no
  Clash Verge profile has, with or without `.yaml`;
- deletes any older copy there, so only one copy of the credentials exists;
- selects the copy in Finder.

Clicking **Finder** again before you drag gives the same name. After you drag it in, the
next copy is `(n+1)`. Clash Verge Rev 2.5.8 offers no other way for another app to add a
Local profile while it runs: its `clash://` import link only creates Remote profiles. It
also offers no way to activate one, so **you need to manually apply the profile in Clash
Verge Rev**.

The dashboard's **Apply in Clash Verge** group lists these steps (labels as Clash Verge Rev
shows them), with an **Open Clash Verge** button that only launches it:

1. **Save** writes the profile file.
2. Click **Finder** next to the profile file, then drag the selected
   `Exit IP Monitor <date> (n).yaml` onto Clash Verge → **Profiles** (or **New** →
   **Local** → **Choose File**). Clash Verge adds it as a Local profile with that name.
3. Right-click the new profile → **Select**, to make it the active profile. Clash
   Verge reloads once.
4. Check **Proxies** → **Proxy Provider** → `tailscale-live` lists `TS-NATIVE`. The
   dashboard's Tailscale status should read **Direct**.

Clash Verge copies the file when you add it, so after changing the proxy in the
dashboard, **Save**, click **Finder**, and drag the new copy in. Tailscale changes need
nothing: they arrive through the provider every 3 seconds. The **provider file** itself
(`/Library/Application Support/ExitIPMonitor/TailscaleVerge/provider.yaml`) is never
imported. The profile's `tailscale-live` entry fetches it from
`http://127.0.0.1:18766/provider.yaml`.

**Remove** in the dashboard deletes the proxy info from the Keychain, the generated file, and the copy;
the profiles Clash Verge added are its own copies. Never commit real proxy addresses or
credentials. The tests use RFC 5737 addresses and dummy values.

**Merging into an existing profile instead.** To keep a profile of your own, merge
these entries into it once (Profiles → right-click it → **Edit File**). Use one root
`proxy-providers:` key and one root `proxy-groups:` key, add the `+.ts.net` line under
your existing `dns: nameserver-policy`, then save and re-activate the profile. Keep
your proxies, DNS, TUN settings, and rules as they are.
The entries:

```yaml
proxy-providers:
  tailscale-live:
    type: http
    url: "http://127.0.0.1:18766/provider.yaml"
    path: ./proxy_providers/tailscale-live.yaml
    interval: 3
    proxy: DIRECT
    health-check:
      enable: false
    payload:
      - name: TS-NATIVE
        type: reject
        udp: true

proxy-groups:
  # ...existing groups stay above this entry...
  - name: TS-DIRECT
    type: select
    use:
      - tailscale-live
    empty-fallback: REJECT

# The DNS policy refers to the stable group name:
# dns:
#   nameserver-policy:
#     "+.ts.net":
#       - "tcp://100.100.100.100:53#TS-DIRECT"
```

Don't add `provider.yaml` to Verge as a profile. **Profiles → New → Remote**, the dialog
that asks for a User Agent, would make it a profile, but it isn't a configuration, and
activating it would replace your whole config. The `proxy-providers` entry above
already fetches it (no User Agent needed). To see it inside Verge, use **Proxies →
Proxy Provider** (`tailscale-live`).

### Dashboard and verification

While the daemon is installed, the dashboard's **Tailscale → Clash Verge provider**
group shows what Clash is served (for example **Direct on utun7**, or **Reject · The
monitor stopped updating**) and when the monitor last checked. It shows
the provider file's location, with **Open File** (read-only in TextEdit) and **Show in
Finder**, and the address it is served at, with **Open in Browser** and
**status.json**; both open inline in a browser. Its **Clash Verge** row shows
**Installed** with **Open**, or that nothing uses the provider until Clash Verge Rev is
installed. The dashboard receives provider updates through its daemon XPC subscription.

From Terminal (no `sudo`; Clash Verge Rev 2.5.8 creates the Mihomo socket owned by
you):

```bash
curl -q --noproxy '*' -sS --max-time 3 http://127.0.0.1:18766/provider.yaml
curl -q --noproxy '*' -sS --max-time 3 http://127.0.0.1:18766/status.json
/sbin/route -n get 100.100.100.100

mihomo_socket="/var/run/clash-verge-service/users/$(id -u)/verge-mihomo.sock"
curl -q --noproxy '*' --unix-socket "$mihomo_socket" -sS --max-time 10 \
  'http://localhost/providers/proxies/tailscale-live/TS-NATIVE'

# Uncached probe: a unique name forces a new exchange with 100.100.100.100. SERVFAIL or
# NXDOMAIN means Quad100 answered; EOF, "interface not found", or "network is unreachable"
# means it did not. (Mihomo keeps serving cached, even expired, answers, so dig can mislead.)
curl -q --noproxy '*' --unix-socket "$mihomo_socket" -sS --max-time 10 \
  "http://localhost/dns/query?name=probe-$(date +%s).<your-tailnet>.ts.net&type=A"
```

When Tailscale is ready, `TS-NATIVE` is `Direct` with the interface that `route`
reports. Check `type` and `interface`, not `alive`, and inspect the provider member
rather than the `TS-DIRECT` group, whose own `interface` field is not the member's.
State changes appear as `tailscale_provider_changed` in the daemon's JSON-lines logs under `/Library/Logs/ExitIPMonitor` and in the Event Log window. Repeated identical provider states do not add lines.

### Timing and limits

Updates take one bounded verification pass plus the profile's three-second provider refresh. Existing long-lived connections cannot move to a new tunnel. The native CLI path remains `/Applications/Tailscale.app/Contents/MacOS/Tailscale`; port and timing are fixed. Missing Tailscale produces Reject; missing Clash Verge leaves the provider unused. A newly updated Tailscale app may time out during macOS's first-run approval and recover on the next pass. When disabled or stopped, the endpoint is absent and Mihomo may retain its last member.

## Refresh recommendation

| Approach | Tradeoffs | Cost | Setup complexity |
| --- | --- | --- | --- |
| **On-demand + network-change check, 30 minutes** | Lowest traffic and battery impact; slower to notice a changed VPN/exit route that does not trigger a network-path event. | Free tiers are ample. | Lowest. |
| **15-minute background refresh (implemented default)** | Detects most VPN, roaming, and public-IP changes promptly. There are about **96 scheduled lookups/day**, plus event checks: each burst of network/lifecycle events costs one immediate lookup and at most one trailing lookup per 5-second window, and a storm lasting over 30 seconds is throttled by the burst allowance (about one lookup per 2 minutes). | Review the selected provider’s terms if the Mac changes routes unusually often. | Low. |
| **5-minute refresh** | About **288 lookups/day**; more battery/network work and more likely to hit a service quota. Use only for frequent, short-lived VPN routing changes. | Prefer an unlimited or paid plan. | Low, but needs provider capacity. |

The default is deliberately **15 minutes**, plus event-driven checks. The periodic trigger runs in the main run loop’s common mode and uses a forced refresh, so menu tracking or a slight timer offset cannot silently turn a 15-minute selection into a 30-minute cadence. Automatic primary lookups—periodic, network, wake, or session/display events—respect a persisted **five-second minimum interval per provider**; startup bypasses it once. **Refresh now** and provider **Test** also bypass the spacing gate, while retaining cooldown and daily-budget checks. A request that would hit a provider called less than five seconds ago goes to the next eligible provider in the pool instead, and is queued only when every enabled provider was called within the last five seconds. On top of that gate, the [lookup budget](#lookup-budget-prompt-checks-vs-api-limits) caps follow-up and routine lookups and per-provider daily usage. It never delays the check for a real network change. The widget itself does **not** perform web requests: the app requests an immediate WidgetKit reload only when rendered IP/location/alert content changes, while its timeline refreshes the shared snapshot at most hourly for relative-age freshness.

### Event-driven refresh policy

The daemon registers macOS system signals and handles them **immediately first, then waits**:

1. The first event after a quiet period requests a lookup **at once** (no debounce) and opens a **5-second event window**.
2. Network-urgency events (path, SystemConfiguration, routing socket, system wake) that arrive inside the window are merged; when the window ends, **one trailing lookup** checks the settled state (for example, a VPN that finished installing its routes after the first event). The trailing lookup opens its own window, so a continuing storm settles to about one lookup per window.
3. Trailing lookups within **30 seconds** of the leading lookup count as network changes and run on time even when the burst allowance is used up, so settings changed a few seconds apart are each checked within one window. Only a storm that keeps going past 30 seconds (a flapping tunnel) has its further trailing lookups treated as follow-ups, which the burst allowance throttles to about one per 2 minutes. The final state is still checked: a deferred follow-up is queued, never dropped.
4. The periodic timer is a routine trigger. App activation and session changes read service state and never request extra IP lookups.
5. Because the five-second gap is per provider, the immediate lookup and the trailing lookup run on **different providers** from the rotation pool, so neither has to wait for the other's gap.
6. A network event that arrives while a lookup is in flight becomes one **recheck** right after that lookup completes, with the event's urgency. A lookup that starts while another is queued (for example, a burst-deferred follow-up) **supersedes** the queued one (`refresh_queue_superseded`), because it already answers it.

| Signal | Mechanism | Behavior |
| --- | --- | --- |
| Daemon startup / user login | System LaunchDaemon / per-user `SMAppService.mainApp` | The initialized service checks once at boot/restart. A UI login item only opens this account’s client; it spends no additional quota. |
| Network route or interface/settings change | `NWPathMonitor` | Requests a refresh immediately (event window applies). Updates whose status, interfaces, gateways, and address families are identical to the previous path are ignored (`network_path_unchanged`). |
| Proxy, DNS, gateway, service order, VPN/IPSec/PPP, or interface list change | SystemConfiguration dynamic store (`NetworkConfigurationObserver`) | Requests a refresh immediately (event window applies). See [Network, proxy, and tunnel triggers](#network-proxy-and-tunnel-triggers). |
| Kernel routing-table, gateway, address, or interface change | `PF_ROUTE` routing socket (`RouteChangeObserver`) | Catches routes that TUN tools install directly (e.g. split `0/1` + `128/1` default routes on `utun`) without updating SystemConfiguration. Kernel noise—ARP/ND entries, per-connection cloned routes, redirects, lookup misses, and loopback/AWDL/`llw`/`anpi` interfaces—is ignored. Requests a refresh immediately (event window applies). |
| Active provider changed | Settings | Choosing a different **Provider**, or removing the active provider from the pool, requests an immediate check with the newly selected provider. Adding or reordering pool entries takes effect at the next lookup without spending one. |
| IPinfo Lite token imported or saved | Administrator-authorized Settings action | Updates the System Keychain and daemon memory, clears the credential pause and requests a check. Remove clears the shared token without a lookup. |
| Mac wakes from sleep | IOKit system power notifications | Requests an immediate refresh; subsequent wake/network events merge into the same event window. |
| Displays wake after sleep/darkness | Per-user workspace notification | Refreshes client state and warning eligibility, without an IP lookup. |
| User session becomes active again | Per-user workspace notification | Fetches the current machine snapshot and only shows a fresh, unacknowledged warning in the active console session. |
| App becomes active | App lifecycle | Reads daemon state; no new lookup. |

macOS doesn’t provide a supported general-purpose “screensaver stopped” notification for apps like this, so the implementation uses the documented display-wake, session-active, and app-active signals rather than private screensaver notifications. If several of these occur together—for example, after opening a laptop—the app performs **one** immediate lookup (plus at most one trailing lookup if a network change followed), never a burst.

> A confirmed country change can still make the already-documented one-time **independent confirmation** request immediately after its primary lookup. That bounded quality check is part of the same refresh transaction, not an additional event-driven primary refresh or provider-rotation fallback.

## IP-location providers and rate-limit policy

| Service | HTTPS | Useful data | Documented limit / consideration | Recommended use |
| --- | --- | --- | --- | --- |
| [IPinfo Lite](https://ipinfo.io/developers/lite-api) | Yes | Public IP, country/continent, ASN, organization | Free account token; IPinfo documents **unlimited** Lite access with no daily or monthly cap. It does not provide city-level data. | Best when reliable country + ASN is enough; preferred for sustained frequent polling. |
| [ipapi.co](https://ipapi.co/api/) | Yes | Public IP, country, city, region, timezone, ASN, organization | Basic fields work without signup; the API documents `429` when quota is exceeded. | **Shipped default** for richer details with no initial setup. At a 15-minute cadence, review the plan/terms before using it long term. |
| [IPWHOIS.io](https://ipwhois.io/documentation) | Yes | Public IP, country, city, region, timezone, ASN, organization | No API key; its documented free endpoint permits 1,000 requests/day and returns `429` with `Retry-After` after the limit. | Available as a primary provider and the default **one-time confirmation provider** when another API detects a country change. |
| [ipapi.is](https://ipapi.is/developers.html) | Yes | Public IP, country **name**, city, region, timezone, ASN, company | Anonymous HTTPS endpoint; documented 100 requests/day limit and reduced fields. The anonymous response has no ISO country code, so the app maps the English country name to one; an unrecognized name fails the lookup (and rotates to the next provider) rather than storing an unconfirmable placeholder. | Included in the explicit rotation pool; a refused request is never retried on it as failover. |
| [WhatIsMyIP.com](https://www.whatismyip.com/api/) | Yes | Public IP, geolocation lookup, proxy check, hostname, WHOIS, and blacklist tools | Requires membership/API key. Free membership supplies **24 calls/day**, below the 96/day 15-minute default; Pro supplies 1,440 calls/day per key. Endpoints are issued inside the account documentation. | Viable for a manual or hourly-refresh profile, or a paid integration after an account/API contract is selected. Not embedded in this first version. |
| [WhatIsMyIPAddress.com](https://whatismyipaddress.com/api) | Website HTTPS; no usable API | Public web lookup only | Its official API page says the public-IP API was discontinued in 2021, geolocation data has no API access, and scripted access to homepage/detail pages is not permitted. | **Never scrape or call programmatically.** It is a useful human-facing reference site, not an app data provider. |
| [ip-api.com](https://ip-api.com/docs/api:json) | **No** on the free endpoint | Country, city, ISP, proxy/VPN signals | 45 requests/minute; free endpoint is HTTP-only and non-commercial. | **Not used** by this app. It is unsuitable as a secure desktop-app default. |
| [MaxMind GeoLite](https://dev.maxmind.com/geoip/geolite2-free-geolocation-data) | N/A (local database) | Offline IP-to-location mapping | Needs database update cadence and a separate secure public-IP discovery request. | A future privacy-oriented offline enrichment option, not the first version. |

### Confirmation, rotation, and scraping policy

Refreshes use the enabled ordered pool, which defaults to `ipapi.co`, IPWHOIS.io, and `ipapi.is`. The active provider is persisted in the daemon’s atomic state file and advances after a successful result. The five-second gap is tracked **per provider**, so an automatic lookup requested shortly after another (such as an event's trailing lookup) runs immediately on the next pool provider that has not been called in the last five seconds (`provider_rotated_spacing`). **Refresh now** bypasses this gap, including with a single-provider pool. Temporary transport, malformed-response, and 5xx failures advance to the next eligible provider after a five-second retry delay; a `429`, authentication error (401/402/403), or provider quota message pauses that provider; the refused request is **not** retried on another vendor. Later lookups (the next network event, timer tick, or **Refresh now**) skip the paused provider in normal rotation (`provider_rotated_cooldown`), exactly as they skip a provider whose own daily budget is used up.

When a **successful** primary API lookup reports a different country from the previously verified result, the app makes exactly **one** call to a different documented HTTPS API:

- Primary `ipapi.co`, `ipapi.is`, or IPinfo Lite → confirmation by **IPWHOIS.io**.
- Primary **IPWHOIS.io** → confirmation by `ipapi.co`.
- If both countries agree, the app stores the new result and shows the configured highlight.
- If the result disagrees or the confirmation API is unavailable, the app retains the last verified country and shows an **awaiting confirmation** message. A later scheduled or manual `Refresh now` retries the normal flow.

This is a **data-quality check**, not rate-limit rotation. It never runs after a `429`, failed primary call, or authentication error, so it cannot be used to evade a provider's quota.

### Lookup budget (prompt checks vs. API limits)

A network change should be checked within seconds, but a flapping VPN, a laptop that sleeps and wakes all day, or someone toggling a TUN tool can generate hundreds of events, and the free providers allow only 100–1,000 requests per day. The daemon therefore classifies every refresh trigger and spends quota in layers (`LookupBudget` in `ExitIPShared`, persisted in the daemon’s atomic state file so relaunching never resets it):

| Urgency | Triggers | Policy |
| --- | --- | --- |
| **Manual** | **Refresh now**, provider change, IPinfo token imported or saved | **Refresh now** bypasses the gap and burst allowance. Provider changes and token actions still use a burst token and respect the 5-second gap. All honor provider cooldowns and daily budgets. |
| **Network change** | Launch, network path, SystemConfiguration (proxy/DNS/gateway/VPN/interface), routing socket (routes/TUN), system wake, trailing lookups within 30 s of the leading lookup, a recheck or queued lookup standing in for one of these | Runs **immediately**, never delayed by the burst allowance (it still uses a token, so it counts against later follow-ups). Subject only to the per-provider 5-second gap (which normally just picks the next pool provider), provider cooldowns, and daily budgets. |
| **Follow-up** | Trailing lookups once an event storm has lasted more than 30 s, scheduled retries | Runs while burst tokens remain. When they run out, the check is **deferred, never dropped**: one lookup is queued for when the next token arrives, so the final network state is always checked. |
| **Routine** | Periodic timer, app activation, screen wake, session activation | Skipped while the last successful result is under **2 minutes** old, and dropped (not queued) when no burst token is available. The next timer tick or event covers it. |

The layers, in the order a request meets them:

1. **Provider cooldown:** a provider that refused requests stays paused until its deadline and rotation skips it (see below). Only when every enabled provider is paused or exhausted do lookups wait, until the earliest deadline (`lookup_all_providers_paused`).
2. **Per-provider daily budget:** each provider gets **80%** of its documented free daily limit: ipapi.co 800, IPWHOIS.io 800, ipapi.is 80, IPinfo Lite unlimited. Primary *and* confirmation calls count. The budget resets at **00:00 UTC**. Normal pool rotation skips an exhausted provider. If every enabled provider is exhausted, lookups pause until the reset and the UI shows the pause time. This self-imposed limit keeps the app under each provider's documented free limit; it is never a reaction to a `429`.
3. **Five-second minimum gap per provider** (startup, **Refresh now**, and provider **Test** bypass it). A request goes to the next pool provider not called in the last five seconds; only when every enabled provider is inside its gap is it queued for the earliest boundary, keeping its urgency. Event-driven requests are additionally shaped by the 5-second [event window](#event-driven-refresh-policy) (immediate lookup, then at most one trailing lookup).
4. **Burst allowance (token bucket):** **6** tokens, refilling **1 every 2 minutes**. Lookups spend a token except for startup, **Refresh now**, and provider **Test**; only follow-ups wait for one and routine checks are dropped without one. Real network changes and manual refreshes always run. A continuous storm therefore costs one leading lookup plus about six trailing lookups in its first 30 seconds, then settles to about one lookup per 2 minutes (≤ 30/hour) instead of one every 5 seconds.

Worst case, a continuous storm is bounded by the refill rate. Distinct network changes (each arriving after the previous event window closed) are each checked at once, so their cost is bounded by the per-provider gap and, ultimately, by each provider's daily budget. Typical use (15-minute timer plus a few network changes) uses roughly 100–150 lookups a day spread across the pool.

### Rate-limit cooldown behavior

A provider is paused when it refuses the client: HTTP `429`; `401`/`402`/`403` (bad or missing credentials, payment required, or a quota block); or a JSON error body that reports a rate or quota limit (for example ipapi.co `"reason": "RateLimited"`). Saving a new IPinfo token clears that provider's pause so the new credential is tried at once. Removing the token also clears the pause but spends no lookup: while IPinfo Lite has no token, rotation skips it (like a paused provider) rather than producing a missing-token error that would hide the location. The daemon loads the saved System Keychain token at startup without UI interaction. Import the old user token explicitly once, or save a new token in Settings. Restart preserves provider cooldowns. If IPinfo Lite is the only enabled provider and no token is available in memory, monitoring waits for a shared token, keeps the last verified result, and spends no request or quota. Anonymous providers remain eligible in mixed pools.

When a primary or confirmation service sends `429`, the app parses both seconds and HTTP-date `Retry-After` forms when supplied; otherwise it applies a conservative **one-hour** pause. It persists the deadline per provider in the daemon’s state file and does not call that provider again until the deadline. The refused request is not retried elsewhere; the next lookup (network event, timer, or **Refresh now**) runs on the next eligible pool provider, as normal rotation would after any lookup. A pause is **not an exit-IP error**: the menu bar, widget, and Control Center keep showing the last verified location, and the dashboard show which provider is paused and until when. Only when every enabled provider is paused or out of daily budget do lookups wait, until the earliest moment one becomes usable. A rate-limited confirmation provider leaves the country change unconfirmed and schedules a later normal check; it is never replaced automatically. Changing to a different provider remains an explicit person-controlled configuration choice.

The app does **not scrape consumer lookup pages**. It calls only providers with a documented application API and automation allowance. In particular, WhatIsMyIPAddress.com explicitly forbids scripted page access and exposes no geolocation API; scraping it would be brittle and contrary to its policy.

### Why not use a popular Google result automatically?

A search result is useful for a **human lookup**, but a menu-bar monitor needs a documented machine API, HTTPS, an explicit usage allowance, predictable structured fields, and permission for repeated automated calls. Popularity does not establish those requirements.

- **WhatIsMyIP.com:** its official API meets the API requirement, but its free 24-call/day allowance only supports roughly hourly refresh, not the implemented 15-minute cadence. It becomes a sound third provider only after a member account provides the official endpoint and the intended refresh profile is selected.
- **WhatIsMyIPAddress.com:** its official policy is decisive: no geolocation API and no scripted access. Automating its website would be both fragile and against the stated policy.
- **The selected providers:** `ipapi.co`, IPWHOIS.io, `ipapi.is`, and IPinfo Lite publish structured HTTPS API documentation suited to a native app. `ipapi.co` is a convenient richer-data default; IPWHOIS.io provides independent confirmation when the country changes; `ipapi.is` supplies a documented keyless HTTPS option for the rotation pool.

### Do not rotate services to bypass a limit

Immediately retrying a refused request on another vendor is rate-limit evasion, can violate service terms, and risks a service ban. This implementation deliberately does **not** fail over after a quota/authentication error. It:

1. never retries the refused request on another provider; the paused provider is only left out of the normal rotation that every lookup already follows, the same way an exhausted daily budget is;
2. honors `Retry-After` when supplied and does not call the provider before that deadline;
3. uses exponential backoff only for transient transport, malformed-response, and 5xx errors; and
4. lets the person select a different provider in Settings for a legitimate product/configuration reason; and
5. proactively stays under each provider's documented free limit with the [lookup budget](#lookup-budget-prompt-checks-vs-api-limits), so a refusal should be rare to begin with.

For a higher refresh rate, use one provider with a plan that explicitly permits the expected volume. Do not scatter requests across free endpoints.

## Folder map

```text
exit-ip-widget/
├── Sources/
│   ├── ExitIPShared/             # Models, typed XPC, providers, storage and credential helpers
│   ├── ExitIPCore/               # Monitoring engine, system observers and runtime logging
│   ├── ExitIPService/            # Native root daemon, authorization, System Keychain and provider HTTP
│   ├── ExitIPMonitorApp/         # Per-user XPC client, dashboard/views and shared OpenIntent
│   ├── ExitIPMonitorWidgets/     # WidgetKit desktop widget and macOS 26 Control Widget
│   └── ExitIPDaemon/             # Service installer; old shell provider retained only for migration fixtures
├── Tests/ExitIPSharedTests/      # Portable shared-core tests
├── Tests/ExitIPServiceTests/     # Real XPC and isolated daemon integration tests
├── Tests/ExitIPDaemonTests/      # Bash tests for the daemon scripts (run.sh runs them all)
├── Packaging/                   # Authoritative Homebrew cask template
├── Configuration/                # App/extension entitlements and LSUIElement Info.plist
├── Scripts/check-build-environment.sh  # macOS/Xcode preflight and optional shared-core test
├── Scripts/install-standalone-swift.sh # Optional runtime download of a SwiftPM-only toolchain
├── Scripts/generate-xcode-project.sh   # Copies sources, creates Xcode project, builds, and logs
├── Scripts/check-refresh-log.sh        # Verifies from a runtime log that network changes refreshed promptly
├── Scripts/check-signed-build.sh       # Read-only signature, architecture, App Group, and widget-extension diagnostics
├── Scripts/package-release.sh          # Universal Release build, ad-hoc sign, zip + .pkg + install.sh + SHA256SUMS into dist/
├── Scripts/pkg/                        # Package preinstall (verified cleanup) / postinstall (launch app)
├── Scripts/install-release.sh          # Template for dist/install.sh: quarantine-free download, verify, install, launch
├── Scripts/lib/adhoc-sign.sh           # Shared inside-out ad-hoc signing helper
├── CHANGELOG.md                        # Release notes; each version's section is published with its release
├── XCODE_ASSEMBLY.md              # Click-by-click project and target assembly guide
└── Package.swift                 # Tests shared core without Xcode UI targets
```

### Start here: get the source

To build the app yourself, clone the repository. The clone's root folder is the **source-kit root**, and every command below runs from it. Do not copy individual Swift files, `Package.swift`, or `Scripts/check-build-environment.sh` into another folder and then run commands there.

```bash
git clone https://github.com/jxz345/exit-ip-widget.git
cd exit-ip-widget
KIT_ROOT="$PWD"
test -f Package.swift && test -d Sources && test -d Configuration
printf 'Using source-kit root: %s\n' "$KIT_ROOT"
```

There are two distinct locations after setup:

| Location | Purpose | Commands run here? |
| --- | --- | --- |
| **Source-kit root** (`exit-ip-widget`) | Contains `Package.swift`, `Sources/`, `Tests/`, `Configuration/`, and `Scripts/`. This is the authoritative copy of the sources. | **Yes.** Run preflight, `swift test`, and the scripts here. |
| **Xcode project folder** (`exit-ip-widget/XcodeProject`) | Created by the generator and ignored by git. It holds the generated `.xcodeproj`, copies of `Sources/` and `Configuration/`, build output, and logs. Never edit the copies. | Only run the final `xcodebuild -project …` command from this guide, or use Xcode's UI. |

## Xcode setup

The repository contains source and Xcode configuration, not an Xcode project; the generator below creates the project.

> For the complete click-by-click procedure—extracting the archive, creating the project, adding every source file, removing Xcode templates, assigning target membership, configuring entitlements, and building—follow **[XCODE_ASSEMBLY.md](XCODE_ASSEMBLY.md)** in order.

### Automated project creation — recommended

`XcodeProject/` is not in the repository; it is ignored by git, and the generator creates it as a self-contained Xcode project. Do not add files to it by hand. From the **source-kit root**, run:

```bash
cd "$KIT_ROOT"
bash Scripts/generate-xcode-project.sh
```

The generator does all of the following in one logged run:

1. Runs the shared Swift Package Manager tests.
2. Copies `Sources/` and `Configuration/` into `XcodeProject/`, preserving the original source kit unchanged.
3. Creates `XcodeProject/project.yml` and `XcodeProject/ExitIPMonitor.xcodeproj` with the app target, WidgetKit extension, embedded extension build phase, target membership, Info plists, and entitlements.
4. Downloads the pinned XcodeGen release only if `xcodegen` is not already installed.
5. Builds the generated project without a signing identity, then ad-hoc signs it, with the app unsandboxed and the widget sandboxed. The app compiles and runs before an Apple team and App Group are configured.
6. Writes the complete stdout/stderr transcript to `XcodeProject/Logs/generate-and-build-YYYYMMDD-HHMMSS-PID.log` and prints that absolute path on success or failure.

For a real signed runnable build, supply the registered App Group and your Apple Developer **Team ID** (not the team name):

```bash
cd "$KIT_ROOT"
bash Scripts/generate-xcode-project.sh \
  --force \
  --app-group group.com.example.exitipmonitor \
  --team YOUR_TEAM_ID \
  --signed-build \
  --open
```

`--force` refreshes only generator-owned content inside `XcodeProject` (`Sources`, `Configuration`, `project.yml`, `.xcodeproj`, and `DerivedData`) and preserves prior logs. If any step fails, attach the log path printed after `FAILED` instead of copying terminal output.

> **Current source-kit compatibility:** The Control Center intent uses an explicit wrapped-value initializer for `ExitIPDestination`. This resolves the Xcode 27 compiler error `IntentParameter<ExitIPDestination> has no member 'dashboard'`. Use `--force` after updating the kit so the corrected source is copied into `XcodeProject/Sources/`.

> **Menu bar and dashboard update:** A retained native status item observes `PublicIPMonitor` and redraws the country, stale, error, and highlight presentation. Clicking it opens the retained regular dashboard window directly. The status item is independent of dashboard and Dock visibility.

After updating an existing source kit, rebuild its generated project with:

```bash
cd "$KIT_ROOT"
bash Scripts/generate-xcode-project.sh --force --open
```

Then quit the running copy, launch the new build, wait for its first lookup, and click the menu-bar flag. The **Exit IP Dashboard** should become key and appear in Mission Control/App Exposé. Move and resize it, minimize it, then click the flag: it restores without recentering. Closing it removes the Dock icon while the menu-bar flag and monitoring remain. Closing Settings or Event Log while the dashboard is minimized must not remove its Dock icon.

### Where the built app is, and what works without an Apple account

After a successful default build, the app bundle and its Unix executable are:

```text
XcodeProject/DerivedData/Build/Products/Debug/ExitIPMonitor.app
XcodeProject/DerivedData/Build/Products/Debug/ExitIPMonitor.app/Contents/MacOS/ExitIPMonitor
```

From the source-kit root, launch the locally built app bundle with:

```bash
open "$PWD/XcodeProject/DerivedData/Build/Products/Debug/ExitIPMonitor.app"
```

### Publishing a release

Build, validate, and publish from this Mac. The GitHub Release workflow is disabled and its
configuration has been removed; pushing a release tag does not run GitHub Actions.
Local artifacts do not receive GitHub build attestations.

```sh
xcrun swift test --verbose
bash Tests/ExitIPAppTests/run.sh
bash Tests/ExitIPServiceTests/run.sh
bash Tests/ExitIPInstallTests/run.sh
bash Tests/ExitIPDaemonTests/run.sh
bash Scripts/package-release.sh
```

`Scripts/package-release.sh` accepts generator options such as `--app-group ID`, builds a
universal ad-hoc signed Release app, verifies the signatures and architectures, and writes:

- `ExitIPMonitor-<version>.zip`, which the Homebrew cask installs. It is created without extended attributes;
- `ExitIPMonitor-<version>.pkg`, the Installer package (scripts in `Scripts/pkg/`);
- `install.sh`, which is `Scripts/install-release.sh` with the repository, version, and package SHA-256 filled in. The repository comes from the `origin` remote, or from `EXIT_IP_RELEASE_REPO=owner/repo`;
- `SHA256SUMS`;
- `exit-ip-monitor.rb`, prepared from `Packaging/exit-ip-monitor.rb.in` with the exact ZIP checksum and current cleanup helpers. Copy it into the companion tap only when publishing.

The script warns when the ZIP or package carries AppleDouble metadata. The ZIP must have none (`zipinfo -1 dist/ExitIPMonitor-<version>.zip | grep -c '\._'` prints 0). The package always carries some, because `pkgbuild` stages a re-stamped copy, and the cask doesn't use it. Publishing a new version (2.0 was the first done this way) is a separate manual action:

1. Bump `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` in `Scripts/generate-xcode-project.sh`, add the `CHANGELOG.md` section, and build.
2. **Gate before publishing.** Point the local tap clone's cask at the new ZIP (`version`, `sha256` from `dist/SHA256SUMS`, and a temporary `url "file:///…/dist/ExitIPMonitor-<version>.zip"`). Then run the install matrix in [Maintainer notes](#maintainer-notes-for-the-next-coding-session) with `HOMEBREW_NO_AUTO_UPDATE=1`: upgrade from the installed version, retained-settings reinstall, provider-disabled reinstall, a password reinstall in a real terminal, uninstall, and a fresh install.
3. Commit, tag `v<version>`, and push. Run `gh release create v<version> --title "Exit IP Monitor <version> (build <n>)" --notes-file <CHANGELOG section> dist/ExitIPMonitor-<version>.zip dist/ExitIPMonitor-<version>.pkg dist/install.sh dist/SHA256SUMS`; do not claim a GitHub build attestation.
4. Download the published assets again and verify their checksums, signatures, and bundle build. Only then restore the cask's GitHub `url` (`v#{version}`, which needs no edit if the pattern is unchanged), keep the checksum, and push `jxz345/homebrew-tap`.
5. `brew update && brew upgrade --cask jxz345/tap/exit-ip-monitor`. The preflight must pass, the installed app must carry no `com.apple.quarantine`, and it must open without a Gatekeeper dialog.

Never replace published assets of an older version; that version is the rollback (revert the tap commit). Local build success alone does not validate downloaded-app Gatekeeper approval.

The Homebrew cask avoids the Gatekeeper approval described in [First launch](#first-launch) by removing this app's download quarantine. For the package and copied apps, only Developer ID signing plus notarization, which needs a paid developer team, removes it.

Inspect a built bundle before installing or requesting a signed build with the read-only diagnostics helper:

```bash
bash Scripts/check-signed-build.sh
```

The default generator build uses no signing identity (it is ad-hoc signed afterwards, with the app unsandboxed), so it is useful as a **local compilation and menu-bar-app test**. You can keep a local copy in `~/Applications` through Finder or by copying the complete `.app` bundle; do not copy only the inner `Contents/MacOS/ExitIPMonitor` executable because it depends on the bundle’s `Info.plist`, embedded widget extension, and resources.

The daemon writes JSON-lines monitoring/provider diagnostics to `/Library/Logs/ExitIPMonitor`. The Event Log combines its recent 500 important lines with personal UI events over XPC. The running UI writes JSON-lines diagnostics to `~/Library/Application Support/ExitIPMonitor/Logs` (one `runtime-<launch time>-<pid>.jsonl` file per launch, so simultaneous launch attempts do not overwrite each other's logs). Set `EXIT_IP_LOG_DIRECTORY` before launching to write runtime logs somewhere else during development; it does not change the instance lock. Before `process_entered`, the app cannot emit runtime events: use the external launch checker's `summary.txt`, security trace and process sample. Its reports and the external cleanup helper’s timestamped TERM/KILL, service-removal, and failure messages are separate from the runtime event stream. No app runtime event is required to stop a pre-entry process. Useful events when checking behavior against this README:

| Event | Meaning |
| --- | --- |
| `daemon_ready` / `daemon_stopped` | Shared service lifecycle, independent of UI sessions. |
| `daemon_client_started` / `daemon_client_stopped` | This user opened/quit the menu-bar client; monitoring continues. |
| `shared_settings_initialized` / `shared_settings_changed` | Authorized import/change, with caller UID and new revision; no secret values. |
| `shared_credential_changed` | Administrator-authorized shared credential update; never includes the token. |
| `user_presentation_changed` | Appearance/acknowledgement changed for the kernel-derived UID. |
| `daemon_storage_failed` / `provider_listener_failed` | Persistent state write or loopback listener failure, visible to clients. |
| `process_entered` / `app_initialized` / `application_did_finish_launching` | Startup milestones with PID, launch ID, version and build. |
| `status_item_created` / `status_item_clicked` / `dashboard_presented` / `dashboard_front_requested` / `dashboard_closed` | Menu-bar creation, click delivery, and dashboard foreground/close requests. Closing removes Dock presence without stopping monitoring. The heartbeat reports dashboard open/visible/minimized/key/active-Space state, app activation, Dock visibility, and status-item visibility; a foreground request alone is not proof that the window became key. |
| `duplicate_instance_blocked` / `duplicate_launch_reopened` / `single_instance_lock_failed` | A duplicate process for the same user exited before app startup, that user’s existing app received its reopen request, or a filesystem error prevented safe per-user single-instance startup. |
| `startup_services_ready` | Non-credential services initialized. UI startup does not access Keychain or rewrite the proxy profile; daemon startup reads its System Keychain token once; build 8 no longer emits `startup_profile_begin`. |
| `keychain_operation` | A credential Load, Save, or Remove begins/completes on the background worker. Fields are `operation`, `outcome`, and `duration_ms`; no account values, credentials, or backend error text. A pending operation can remain unfinished while the main-thread heartbeat continues. |
| `dashboard_presented` / `app_ready` / `app_terminating` | Dashboard shown, main queue responding, and shutdown. `launch_heartbeat_failed` records a diagnostic write failure. |
| `monitor_started` / `monitor_stopped` | IP monitor start and stop. |
| `tailscale_provider_changed` | What the Tailscale → Clash Verge responder serves changed (`served` direct/reject, `interface`, `reason`). Recorded only on a change; the daemon's 2-second rewrites never add a record. The first reading after launch is recorded once. |
| `daemon_install_started` / `daemon_install_succeeded` / `daemon_install_cancelled` / `daemon_install_failed` | Dashboard installation lifecycle, also shown in the Event Log. Includes the local diagnostic log path, never passwords. Success requires the single service to load and respond over XPC with the matching build. |
| `clash_profile_written` | The app wrote `~/Library/Application Support/ExitIPMonitor/clash-verge-profile.yaml` (`path` only; the proxy is never logged), after the dashboard's automatic load, **Load proxy info**, or **Save**. `clash_profile_write_failed` (`error`) reports a problem. |
| `clash_profile_copy_written` | The profile file's **Finder** wrote the copy to drag into Clash Verge (`name`: the copy's file name, such as `Exit IP Monitor 2026-10-25 (3).yaml`; never its contents). A failure is logged as `clash_profile_write_failed`. |
| `provider_health_changed` | Provider attempt/success/failure history is persisted for the Settings health panel. |
| `refresh_requested` | A refresh was asked for. `trigger` is `startup`, `manual`, `periodic`, `network_path`, `network_configuration`, `route_change`, `system_wake`, `queued`, `trailing`, `retry`, `recheck`, `provider_changed`, or `settings_changed`. `urgency` is `manual`, `network_change`, `follow_up`, or `routine` (see [Lookup budget](#lookup-budget-prompt-checks-vs-api-limits)). The existing `startupBypass` field is also `true` for **Refresh now** and provider **Test**, indicating that the gap and burst allowance are bypassed; cooldowns and daily budgets still apply. |
| `refresh_queued` | The request was deferred; `reason` is `provider_gap` (every enabled provider was called within 5 seconds) or `burst_budget` (no burst token; only ever with `urgency=follow_up`), `urgency` is kept for the queued lookup, and `notBefore` is when the single queued lookup runs. |
| `refresh_queue_superseded` | A lookup started while one was queued; the queued lookup (`notBefore`) was cancelled because the started one answers it. |
| `refresh_skipped` | A routine trigger did not spend a lookup; `reason` is `fresh` (result under 2 minutes old), `burst_budget`, or `event_window` (absorbed by the immediate lookup of an open event window). |
| `refresh_event_merged` | A network event arrived inside an open event window and was merged into the single trailing lookup at `trailingAt`. |
| `network_path_unchanged` | `NWPathMonitor` reported an update with the same status, interfaces, gateways, and address families, so no refresh was requested. |
| `provider_rotated_spacing` | The active provider was called less than 5 seconds ago, so this lookup moved to the next eligible provider (`from`, `to`, `trigger`). |
| `provider_rotated_cooldown` / `lookup_all_providers_paused` | The active provider is paused after refusing requests, so rotation moved on (`from`, `to`, `trigger`); or every enabled provider is paused or exhausted and lookups wait until `resumeAt`. |
| `provider_rotated_daily_budget` / `lookup_daily_budget_exhausted` | The active provider used its daily budget, so rotation moved on; or every enabled provider is exhausted and lookups pause until `resetAt` (00:00 UTC). |
| `refresh_coalesced_in_flight` | An automatic event arrived during a lookup and was folded into one post-lookup recheck. Concurrent manual requests share the in-flight check without scheduling an extra one. |
| `lookup_started` / `lookup_succeeded` / `lookup_failed` / `lookup_rate_limited` | Primary lookup lifecycle, with `provider`, `country`, or error `category`. `lookup_rate_limited` covers every provider refusal (`429`, `401`/`402`/`403`, quota message) that set a cooldown (`retryNotBefore`); it does not set the error indicator. |
| `diagnostic_preferences_changed` | Log IP redaction and retention settings changed. IP addresses are redacted unless explicitly enabled; only text that parses as a real IPv4/IPv6 address is replaced, so timestamps such as `notBefore` and `resumeAt` stay readable. |
| `debug_simulation_started` / `debug_simulation_cleared` | A DEBUG-only in-memory scenario was started or cleared. |
| `provider_rotated_after_failure` | A temporary failure advanced to the next eligible provider. |
| `provider_test_skipped` | The Settings **Test** button was pressed for a provider that is paused (`reason=provider_paused`) or out of daily budget (`reason=daily_budget`), or IPinfo Lite has no session token (`reason=token_unavailable`); nothing was called, and `resumeAt` says when it is usable. |
| `lookup_cancelled` / `lookup_discarded_after_stop` | A lookup was cancelled, or finished after the monitor stopped and its result was ignored. |
| `confirmation_started` / `confirmation_result` / `confirmation_failed` / `confirmation_deferred` | The one-time independent check after a country change. `confirmation_result.agrees` shows whether the change was accepted; `confirmation_deferred.reason` is `provider_paused` or `daily_budget`. |
| `widget_reload_requested` | Rendered widget content changed, so WidgetKit was asked to reload. |
| `network_configuration_changed` | The SystemConfiguration dynamic store reported changed `keys` (proxy, DNS, IPv4/IPv6, service, interface); a `network_configuration` refresh trigger follows. |
| `network_configuration_monitor_unavailable` | The SystemConfiguration observer could not be registered (`step`, `error`); proxy/DNS changes then rely on the other observers. |
| `route_monitor_unavailable` | The kernel routing socket could not be opened (`errno` included); SystemConfiguration and `NWPathMonitor` triggers still work. |
| `allowlist_warning_presented` / `allowlist_warning_cleared` | The verified exit IP is outside the allowlist and the warning window was shown for `ip` (once per address); or the window was closed because the address became allowed or the list was emptied. |
| `ipinfo_token_removed` | The shared IPinfo token was removed; rotation skips IPinfo until a token is imported or saved. |
| `indicator_error_set` / `error_cleared` / `country_change_dismissed` | User-visible error and highlight state. |

| Goal | Apple Account / developer team needed? | Result |
| --- | --- | --- |
| Compile and locally inspect the app bundle | **No** | The app bundle is created at the Debug path above and ad-hoc signed. |
| Menu-bar app, launched locally | **No** | Install/initialize the service with administrator authentication first. The ad-hoc signed UI is unsandboxed. |
| Widget and Control Center state transport | **No App Group required** | Sandboxed extensions query the daemon with the narrow Mach lookup entitlement. Validate registration and rendering on the target OS before release. |
| Copy the app to another Mac | **No** | Install the complete bundle and configure its background service. Copied apps may need Gatekeeper approval. See [Install](#install). |
| Sign, install reliably, or distribute without a Gatekeeper prompt | **Yes** | Supply a real team and registered App Group using `--signed-build`. Notarization is additionally required for distribution outside Homebrew without the **Open Anyway** step. |

App Groups remain available for legacy migration and cache storage. Current machine state is read through the service, so a shared container is no longer the app-to-widget transport.

### Prerequisites

- A **Mac** running a macOS version supported by the selected Xcode. For example, Apple lists **macOS Sequoia 15.6+** for Xcode 26; consult Apple’s current system-requirements table when selecting a newer Xcode release.
- **Full Xcode** with a **macOS 26-or-newer SDK** to compile the Control Center control. The standalone Command Line Tools package does not include `xcodebuild`, so it is not sufficient for this app and its WidgetKit extension.
- macOS 14+ deployment target for the menu-bar app and normal WidgetKit widget.
- macOS 26+ at runtime for the Control Center control.
- The widget needs its exact Mach-service lookup entitlement. Team-signed builds may additionally use a registered App Group on app and extension; ad-hoc builds omit that entitlement.

> Xcode already includes the appropriate Swift compiler. Do **not** download another toolchain to build this app. A separate internet-download script exists only for optional Swift Package Manager testing: `bash Scripts/install-standalone-swift.sh`. The standalone compiler cannot build the SwiftUI app, WidgetKit extension, or Control Center control.

### Build-environment preflight and recovery

Run this **on the Mac that will build the project**, from the source-kit root established above. It is inspection-only: it makes no installations and changes no signing settings.

```bash
cd "$KIT_ROOT"
bash Scripts/check-build-environment.sh
# After the environment passes:
bash Scripts/check-build-environment.sh --test
```

If the script was copied out of the source kit—for example, into `~/Downloads`—point it back to the clone explicitly:

```bash
bash ~/Downloads/check-build-environment.sh --project /path/to/exit-ip-widget
```

The script checks macOS version, the active developer directory, full Xcode and first-launch status, Xcode license, macOS SDK version, Swift, project/entitlement plist syntax, placeholder App Group identifiers, local signing identities, and (with `--test`) the portable shared-core tests. It exits nonzero when a blocking build prerequisite is missing. If Command Line Tools are active while a full Xcode app is detected, it reports **one actionable developer-directory failure** and intentionally skips dependent `xcodebuild`, license, and SDK checks until Xcode is selected. With `--test`, it now prints the exact `xcrun swift test --package-path … --verbose` command and saves the full compiler output as `swift-test.log` in the source-kit root; the first earlier `error:` line is the actionable diagnosis, not SwiftPM’s final summary.

| Preflight finding | Install or recovery method |
| --- | --- |
| **Not macOS** | Build the SwiftUI app and WidgetKit extension on a Mac. Linux—including this source-kit preparation environment—cannot build the Xcode targets. |
| **Host macOS is too old for Xcode 26** | Update macOS through **System Settings → General → Software Update**. Xcode 26 needs macOS Sequoia 15.6 or later; verify the latest compatible pairing in Apple’s [Xcode system-requirements table](https://developer.apple.com/xcode/system-requirements/). |
| **Full Xcode or `xcodebuild` missing** | Install the current compatible Xcode from the [Mac App Store](https://apps.apple.com/us/app/xcode/id497799835?mt=12) or Apple’s [Downloads](https://developer.apple.com/download/). Command Line Tools alone are not enough for `xcodebuild` or WidgetKit project builds. |
| **Source-kit root not found** | Do not run an isolated copied script as though its parent folder were the kit. `cd` into the cloned `exit-ip-widget` directory, or supply `--project /path/to/exit-ip-widget`. |
| **Command Line Tools missing** | After full Xcode is installed, this is normally already satisfied. For command-line-only tools, run `xcode-select --install` and accept the macOS dialog. Apple documents this package and its version limits [here](https://developer.apple.com/documentation/xcode/installing-the-command-line-tools). |
| **Wrong active developer directory** | Point Terminal at the installed Xcode: `sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer`. Substitute the actual path for a beta or renamed Xcode app, then rerun the preflight. |
| **First-launch components incomplete** | Run `sudo xcodebuild -runFirstLaunch`, then rerun the preflight. |
| **Xcode license not accepted** | Run `sudo xcodebuild -license accept`, then rerun the preflight. |
| **macOS SDK below 26** | Update or install an Xcode release that includes macOS SDK 26 or newer; there is no separate SDK install recommended for this project. Rerun `xcrun --sdk macosx --show-sdk-version` to confirm. |
| **Swift unavailable** | Re-select the full Xcode developer directory with `xcode-select --switch`, or reinstall the selected Xcode release. |
| **No local signing identity** | In Xcode, open **Settings → Accounts**, sign in with the Apple Account that belongs to the developer team, select that team for both targets, and enable **Automatically manage signing**. |
| **Placeholder App Group remains** | Register an App Group in the developer account, replace `group.com.example.exitipmonitor` in the three listed files, then enable **App Groups** in **Signing & Capabilities** for both targets. |
| **Mac is below macOS 26 at runtime** | You can build and test the menu-bar app and normal widget, but the Control Center control cannot appear until the app runs on macOS 26 or later. |

### Create targets and assign membership

Use `Scripts/generate-xcode-project.sh`; it creates all three targets, embeds the native daemon, and signs it before sealing the containing app. The older [manual assembly guide](XCODE_ASSEMBLY.md) describes the two-target layout and is not sufficient for 3.0. For custom projects, follow the generator's target definitions:

| Sources | App | Widget | Daemon |
| --- | --- | --- | --- |
| `ExitIPShared/*.swift` | Yes | Yes | Yes |
| `ExitIPMonitorApp/*.swift` | Yes | Only `ExitIPIntents.swift` | No |
| `ExitIPMonitorWidgets/*.swift` | No | Yes | No |
| `ExitIPCore/RuntimeLog.swift` | Yes | No | Yes |
| Other `ExitIPCore/*.swift` | No | No | Yes |
| `ExitIPService/*.swift` | No | No | Yes |

The daemon is a macOS command-line-tool target with `EXIT_IP_DAEMON`, Security, SystemConfiguration, Network and IOKit. The app depends on it and embeds the executable as `Contents/MacOS/ExitIPMonitorDaemon`. Keep app and widget entitlements from `Configuration`; both use the exact service Mach name. App/daemon deployment is macOS 14+, with a macOS 26 SDK needed for Control Center. Never edit generated copies under `XcodeProject`.

### Initial configuration

1. Run the built app, install/repair the service in **Shared background monitoring**, and authorize **Use This Account’s Settings** if the service is uninitialized.
2. Open **Settings** from the app menu (Cmd-,) or **Settings** in the dashboard.
3. Choose the menu-bar **Display** mode: `Color flag` (default), `Country name`, `Country code`, or `Flag and country name`. The menu label contains only that country presentation (plus the country-change indicator when applicable), with no extra globe icon.
4. Use **Highlight country changes** to enable/disable all future country-change highlights. A visible alert can also be dismissed individually from the dashboard. With it enabled, a country change must agree with a second documented API before it is highlighted.
5. Enable **Show menu-bar app at login** in Monitoring or Settings → Startup if this account should show the icon automatically. The daemon already starts at boot. macOS can require approval; use **Open Login Items Settings** if requested. The login item points to the app bundle at its current path, so copy `ExitIPMonitor.app` to `/Applications` and launch it from there before enabling it. A build run from `XcodeProject/DerivedData` is replaced on every `--force` regenerate.
6. Use **Refresh now** in the dashboard whenever an immediate lookup is needed. It runs at once on the next pool provider not called in the last five seconds; only when every enabled provider was called within five seconds does it queue for the earliest boundary.
7. Leave the default provider pool (`ipapi.co`, IPWHOIS.io, `ipapi.is`) for a no-token trial, or add/select **IPinfo Lite** and save a free token (the token field appears whenever IPinfo Lite is in the pool). The token stays in the System Keychain and is loaded automatically by the daemon. Importing a previous account token is explicit; opening Settings never reads the secret. The daemon’s active provider is persisted and advances after every successful lookup, so a service restart continues from wherever the rotation left off rather than always starting with `ipapi.co`.
8. Add the desktop widget from the widgets gallery. On macOS 26+, add the Control Center control from the Controls Gallery.

### Network, proxy, and tunnel triggers

In addition to the periodic check and `NWPathMonitor`, the app subscribes to macOS **SystemConfiguration** dynamic-store notifications for:

- current global proxy configuration;
- global IPv4/IPv6 route and DNS state;
- per-service IPv4/IPv6, DNS, and proxy configuration;
- PPP, IPSec, and VPN service state;
- link, IPv4, and IPv6 state for network interfaces, including `utun` tunnel interfaces;
- the interface list (an interface such as `utun` appearing or disappearing); and
- the configured service order, which decides the primary service and gateway.

It also reads the kernel **routing socket** (`PF_ROUTE`) for route add/delete/change, address add/remove, and interface-state messages. This catches TUN tools (Clash, sing-box, Surge enhanced mode, etc.) that install split default routes directly without touching SystemConfiguration. Kernel bookkeeping messages and Apple peer-to-peer interfaces are filtered out (`RouteChangeFilter`), so ordinary traffic never causes a lookup.

Changing a gateway, route, interface, system proxy, or enabling/disabling a TUN/VPN therefore requests a refresh **immediately**. Further changes in the next five seconds are merged into one trailing lookup at the end of that window; if the earlier lookup is still in flight then, the trailing check runs right after it completes. Automatic sources after startup—paths, SystemConfiguration notifications, wake, and periodic checks—respect the **five-second minimum interval per provider** (**Refresh now** and provider **Test** bypass it): a lookup goes to the next pool provider outside its gap, and only when every enabled provider was called in the last five seconds does the UI show the queued time and perform one lookup at the earliest boundary. Successful lookups advance through the enabled provider pool, and temporary failures rotate through each eligible provider before exponential backoff; `429` and authentication failures pause the affected provider, and later lookups skip it in rotation until its deadline.

## Maintainer notes (for the next coding session)

These notes cover what this project learned about shipping an ad-hoc signed, unnotarized app
through Homebrew on macOS 27, and how to change install or release code without breaking the
working install. Read them before touching the cask, the installers, or launch behavior.

### Homebrew cask design (`jxz345/homebrew-tap`, `Casks/exit-ip-monitor.rb`)

- **`preflight_steps`** runs `/usr/bin/codesign --verify --deep --strict` and then `/usr/bin/xattr
  -dr com.apple.quarantine` on `{{staged_path}}/ExitIPMonitor.app`. Homebrew 7 runs preflight
  steps silently, inside its cask sandbox, before it moves the app.
  - Why: Homebrew quarantines every download, including `file://` URLs, and has no
    `--no-quarantine` any more. A quarantined unnotarized app needs **Open Anyway**, and macOS can
    park that approval (see below). Without quarantine, Gatekeeper still scans the app
    (`GK evaluateScanResult: 2`) but shows no dialog.
  - Working on the staged copy has two advantages: a bad signature aborts the install before
    `/Applications` changes, and no App Management permission is needed. These are Sleepless's
    manual recovery commands, applied before the first launch.
- **`postflight_steps`** runs `/bin/bash …/daemon.sh install` with `sudo: true`,
  `must_succeed: false`, for every install. The old optional-provider opt-out marker does not skip the required service. The script runs through `/bin/bash` because Homebrew must not execute a
  bundled script directly. A failure, such as cancelled authentication, leaves the app installed; monitoring is unavailable until dashboard **Install Service** or **Repair Service** succeeds.
- **`uninstall`** sends a graceful `quit:` (an AppleEvent), then runs the embedded cleanup helper.
  It must succeed and must not run as root. It invokes the root-owned service manager through the `sudo -n` removal grant. The block between `BEGIN/END GENERATED CLEANUP` is generated: run
  `python3 Scripts/sync-homebrew-cleanup.py <cask>`, and add `--check` to verify it. Installed
  casks keep their own cached uninstall hook in `Caskroom/exit-ip-monitor/.metadata`.
- **Tests:** `Tests/ExitIPInstallTests/cask_test.rb` asserts exactly these steps. Run it through
  `EXIT_IP_CASK_PATH=<cask> bash Tests/ExitIPInstallTests/run.sh`, and run `brew style <cask>`.
- **Homebrew facts that mattered:**
  - `reinstall` and `upgrade` run the old cask's uninstall first.
  - A same-version rebuild is not an upgrade, so ship a new `version`.
  - Changing the `url` purges the cached download.
  - `HOMEBREW_NO_AUTO_UPDATE=1` keeps uncommitted edits in the local tap clone
    (`/opt/homebrew/Library/Taps/jxz345/homebrew-tap`).

### Gatekeeper on macOS 27: the parked approval

- **Symptom:** after `brew install`, the app never starts. Its 96 KB process samples at
  `_dyld_start + 0`, and no app code ran: the runtime log has no `process_entered`. A restart
  appears to fix it.
- **Cause:** **Open Anyway** asks LocalAuthentication for Touch ID with a **Use Password**
  button. If loginwindow has a background Touch ID request running (seen on a Mac with a second
  account), Use Password lets that request cancel the approval. macOS then parks the approval
  until the next screen unlock, logout or restart, or another Touch ID use. While it is parked,
  every launch from that path waits, quarantined or not.
- **Log signature** (use `/usr/bin/log show`, because `log` is a zsh builtin; Info messages
  rotate within hours):

  | Process | Messages |
  | --- | --- |
  | `syspolicyd` | `Prompt shown (6, 0)` (Not Opened) and `(6, 0x1)` (Open Anyway); `Getting auth to allow override`; `waiting on another evaluation`; later `Allowing code due to user override` |
  | `coreauthd` | `FallbackButtonPressed`, then `Canceled by another authentication` (Subcode 34); `replaced: <AuthenticationInProgress … pid:<loginwindow>>`; on release, `retrying request` |

- **Recovery:** lock the screen (Control-Command-Q) and unlock it, which releases a parked
  approval within seconds. Approving with Touch ID completed at once. Removing quarantine does
  not release a parked approval.
- **Trials need fresh identities.** Once an app has been approved and has run, Gatekeeper skips
  it at that path, even with a new code hash and fresh quarantine. To test first-launch behavior:
  - make a variant with a new `CFBundleIdentifier` (`plutil`), re-sign it with `codesign --force
    --sign - --preserve-metadata=entitlements,flags,runtime`, and zip it with
    `ditto -c -k --keepParent --noextattr`;
  - point the cask at it with a `file://` URL and its checksum;
  - install with `brew install --cask --appdir=<new folder>`;
  - revert the cask afterwards.
- **`com.apple.provenance` is not a cause.** Every file written by an agent session carries it,
  and it is harmless.

### The install matrix (the gate before any tap push)

Run every case from the local tap clone with `HOMEBREW_NO_AUTO_UPDATE=1`:

| Case | How | Expect |
| --- | --- | --- |
| Failed password | Cancel service authentication during Homebrew install | App remains installed; monitoring is unavailable and dashboard setup is retryable. |
| Provider disabled | Disable the optional provider, then reinstall | Required service returns, retained provider setting stays disabled, no listener is opened. |
| Password | Install in a real terminal | One system job responds over XPC; removal grant is root:wheel 0440; after initialization monitoring runs. |
| Uninstall | `brew uninstall` | Installed clients and system job stop; executable/plist/grant disappear; machine and personal data remain. |
| Upgrade / fresh install | `brew upgrade`, or `brew install` after uninstall | As above, on the new version |

Each run also checks:
- `xattr -lr /Applications/ExitIPMonitor.app | grep -c com.apple.quarantine` prints 0;
- `codesign --verify --deep --strict` passes;
- `bash Scripts/check-launch.sh --launch --timeout 60` reports ready;
- the runtime log has `lookup_succeeded`;
- `syspolicyd` logs no `Prompt shown` or `Getting auth`.

Guardrails:
- Keep the preflight byte-identical.
- Ship cask-only changes separately from app rebuilds.
- Never replace the published assets of an older version, because reverting the tap commit is
  the rollback.

### App techniques worth reusing

- **The Dock icon is the menu-bar label.** `StatusItemController.update()` passes the same
  `MenuBarCountryLabel` to `DockIconController`, which draws it into `NSApp.applicationIconImage`:
  - It renders with `ImageRenderer` in two passes: measure at 1×, then render at the scale that
    fills a 512 × 512 canvas, so emoji use large glyphs.
  - It re-renders only when `MenuBarCountryLabel.visualKey` or the system appearance changes.
  - The exception: while the exit IP is outside the allowlist (`showsAllowlistStop`), it draws
    only `MenuBarCountryLabel.allowlistStop`, the red stop sign, under one fixed key, so flag or
    style changes don't re-render it.
  - It re-applies the icon after `setActivationPolicy`.
- **⌘Q closes the windows.** A hidden app-menu item with `allowsKeyEquivalentWhenHidden` owns
  ⌘Q, and the visible Quit item has no shortcut. Quit AppleEvents are unaffected.
- **Telling quits apart in the log.** `performKeyEquivalent:` → `terminate:` means a keyboard
  shortcut. `Handling Quit AppleEvent` means Homebrew or `osascript`.
- **Launch at login:** the choice is stored (`exit-ip.launch-at-login.v1`), and
  `LoginItemPolicy` + `LoginItemSync` re-apply it after `markReady()`.
- **Keychain:** use `CredentialSession` only. It serializes work on a background queue, so a
  pending Keychain prompt never blocks the main thread; build 7 waited 43 s that way.
  `loadIfNotLoaded()` is the dashboard's single automatic read.

## Test plan

| Check | Expected result |
| --- | --- |
| Boot and logout | After authorized initialization, reboot without opening a UI; verify exactly one root daemon and continuing checks. Log all users out, then back in: quotas/cooldowns persist and no second daemon starts. |
| Multiple users | Keep two accounts logged in with their UIs open. Both see shared snapshot/settings, Refresh calls coalesce, appearance/dismissals are independent, and quitting either UI changes no service lifecycle. A stale admin settings edit returns a conflict. |
| IPC recovery | Kill/restart the daemon; clients show unavailable then reconnect. An incompatible protocol produces an explicit update/repair message. Widgets never start private monitoring. |
| Install on another Mac | Build locally, verify checksums, both architectures and strict signatures, and inspect archives for AppleDouble metadata. With the updated cask, a fresh installation asks for the password once and creates the single monitoring service and its narrow removal grant. A Homebrew install must open without a Gatekeeper dialog and produce a fresh matching heartbeat and a successful lookup. Package setup installs the service; shell/copy installs use the dashboard setup step. A local unquarantined build does not count as a downloaded-app test. |
| Homebrew service setup | Install/reinstall prompts once for service installation, verifies XPC readiness, and removes both legacy jobs. Cancellation leaves a retryable setup state. Provider enablement is a separate admin setting. Uninstall uses only the fixed manager removal grant and retains state. Run `bash Tests/ExitIPInstallTests/run.sh` against the prepared cask. |
| Homebrew first launch | Test with an app identity this Mac has never approved, because an approved one opens regardless. Run `brew install --cask jxz345/tap/exit-ip-monitor`, then `brew reinstall`. Both preflight steps pass, and `xattr -lr /Applications/ExitIPMonitor.app \| grep -c com.apple.quarantine` prints 0. After `open` there is no Not Opened or Open Anyway dialog. The runtime log has `app_ready` and `lookup_succeeded`, and `syspolicyd` logs `GK evaluateScanResult: 2` without `Prompt shown`. A bundle that fails `codesign --verify` aborts the install before `/Applications` changes. With an approval parked by an earlier **Use Password** attempt, lock and unlock the screen: `Allowing code due to user override` follows and the waiting app starts. `EXIT_IP_CASK_PATH=<tap>/Casks/exit-ip-monitor.rb bash Tests/ExitIPInstallTests/run.sh` checks the declared steps. |
| First launch and reopen | On a Mac that has never run the app, the first launch opens the dashboard. Quit and relaunch: only the menu-bar item appears. Open the app again from Finder while it runs: the dashboard comes forward. |
| Dock icon matches the menu bar | Open the dashboard: the Dock and Cmd-Tab icon is the menu bar's flag. Switch Settings → Menu bar style (flag → code → name → flag): the Dock follows each change immediately. Disconnect the network until a lookup fails: both show the red stop symbol, then the flag again after a successful lookup. A confirmed country change shows the same highlight in both. Add an allowlist address other than the current exit IP: the menu bar shows the flag with a red stop icon beside it, and the Dock shows only the red stop icon (changing the menu-bar style doesn't change the Dock); empty the list and both return to the flag. Switch light/dark: the Dock's text and symbol stay legible. `bash Tests/ExitIPAppTests/run.sh` checks one render per visible change and writes `menubar-*.png` / `dock-*.png` pairs. |
| Cmd-Q keeps the app | With the dashboard (or Settings, Event Log) in front, Cmd-Q closes the windows; the flag, monitoring and process stay (`windows_closed_by_shortcut`). **Quit Exit IP** and the app menu's Quit quit; `brew uninstall` and `osascript -e 'quit app id "com.example.exitipmonitor"'` still quit. |
| Launch at login remembered | Turn Launch at login on, `brew reinstall`, open the app: the setting is still on, and the runtime log shows `login_item_synced` (`register` when macOS had dropped it). Turn it off: the next launch unregisters a leftover. Restart: the app starts at login. |
| Credential access | Verify daemon startup reads the System Keychain once with no UI, and other accounts see availability but never the token. Standard users can view/test but cannot change it without admin authorization. Explicit import reads only the importing account’s old token. Proxy info remains personal and loads once per dashboard session. Test boot-time retrieval, replacement and removal on a disposable macOS install before release. |
| Launch failure diagnostics | A blocked process without `app_ready`, an old build, an old heartbeat, or another bundle cannot produce success. A failure exits within its deadline and saves app-specific evidence. `bash Tests/ExitIPInstallTests/run.sh` passes. |
| First launch | Complete service installation and authorized settings import first. The menu label then shows the daemon’s current result; subsequent UI launches spend no lookup. Dashboard shows public IP, provider data, absolute **Last updated** time, and relative age. |
| Menu settings | Switching among name, country code, flag, and flag+name immediately changes the menu-bar item; a stale result is labeled after twice the selected interval. |
| Open Settings | The dashboard Settings button and app-menu Cmd-, open or restore the full Settings window. Closing Settings leaves the dashboard and its Dock icon intact, including when the dashboard is minimized. Closing the dashboard hides the Dock icon even if Settings or Event Log remain open. No settings window opens automatically. |
| External launch trace | Run `diagnose-launch.sh --trace --launch --timeout 180` before approval. Success requires a fresh matching heartbeat and `result=ready`; a pre-entry stall yields `result=blocked_before_entry` only with process-sample evidence. Confirm an early sample survives cancellation, cancellation remains a separate result, app-associated pending evaluations appear in the summary, redacted identities remain unattributed, missing permissions appear in `incomplete.txt`, and Ctrl-C or timeout leaves no collector running. Repeat opening and a Homebrew reinstall with the cached ZIP cleared; one successful launch is not a permanent-fix claim. |
| Open Dashboard | Click the persistent menu-bar flag: the dashboard opens directly with a Dock icon and Cmd-Tab entry. Verify Mission Control/App Exposé and full screen. Minimize and click the flag to restore; repeated clicks keep one window/process. Move/resize, close/reopen, and restart: the frame is preserved. Disconnect its display: the title bar stays reachable. Closing hides the Dock icon, keeps the flag, and leaves lookup and provider services running. |
| Dashboard layout and editing | Check light/dark appearances at 1000 × 860 and 520 × 380. Buttons have consistent heights and paired widths, fields stay usable, long text wraps, paths truncate with full tooltips, and the footer remains available. Enter unsaved proxy values, resize across 960 points repeatedly, and confirm values/focus survive without Save. Check missing/installed/installing/failed provider states, keyboard focus, and accessible names on removal and profile fields. |
| Manual refresh | Selecting **Refresh now** in the dashboard fetches the current public IP at once. After completion, press it again within five seconds, including with a single-provider pool: another lookup starts immediately and updates the snapshot. The log shows `trigger=manual`, `startupBypass=true`, and no `provider_gap` queue for that request. Provider cooldowns and daily budgets still apply. |
| Proxy, gateway, route, or TUN/VPN change | Change a macOS proxy setting, switch Wi-Fi/Ethernet (new gateway), connect/disconnect a TUN/VPN, or toggle a TUN tool's routes. The log shows `refresh_requested` with `trigger` `network_configuration` or `route_change`, and a lookup starts at once (no debounce). Follow-up events log `refresh_event_merged`, and about five seconds later one `refresh_requested` with `trigger=trailing` runs on a different provider. A confirmed country difference creates a yellow highlight for 10 minutes. |
| Timer cadence | A 15-minute periodic timer always forces the due lookup; a one-second timing offset cannot cause an extra 15-minute skip. |
| Idle network | With no network changes for several minutes, no `route_change` or `network_configuration` refresh appears in the log (kernel noise is filtered). |
| Event burst / event window | Trigger route, DNS, network path and system-wake events within five seconds. One primary lookup and at most one trailing lookup run. UI/session activation only fetches state. |
| Login launch | Enable **Show menu-bar app at login**, sign out/in, and verify that user’s icon appears. Turning it off must not stop boot monitoring. |
| Country-change confirmation | A changed primary country is highlighted only when the independent confirmation API returns the same country; disagreement retains the last verified country and shows a confirmation message. |
| Dashboard change controls | During a highlighted change, the dashboard shows Dismiss and Turn Off Highlights with consistent sizes. Dismiss clears only the current notice; Turn Off Highlights also disables future highlights. Long country names wrap without overlapping actions. |
| Disable highlights | Turning off **Highlight country changes** clears the current alert and prevents all future change highlighting until re-enabled. |
| Same-country IP change | IP changes in dashboard/widget but does **not** create a country alert. |
| Widget | Reads XPC state even with every UI closed, without a provider lookup. UI-observed material changes request a reload; otherwise the hourly timeline fetches current state. Service outages hide location and label cached data stale. Validate the sandbox entitlement with a signed/ad-hoc installed extension. |
| Control Center (macOS 26+) | Resized tile exposes country code, public exit IP, last-update time, and warning symbol for a confirmed change; dashboard remains optional. Tapping the tile opens the **Exit IP Dashboard** window. |
| Quit command | Explicit Quit removes only that user’s UI. Another account’s UI and the daemon keep running. Cmd-Q closes windows; closing the dashboard leaves the status item available. |
| Single instance per user | Reopen normally, force `open -n`, and launch the bundled executable while the app is already running: only one UI client stays alive for that user, and normal reopening shows their dashboard. Launch two executables concurrently with no app running: only one reaches `app_ready`. Quit or terminate it, then relaunch: the leftover lock file must not block startup. Development and installed copies share the same per-user lock. With Fast User Switching, launch under two accounts without logging either out: both UI clients stay alive and use the same daemon; reopening in one account must not affect the other account’s dashboard. |
| Rate limit | A `429`, `401`/`402`/`403`, or quota error body pauses that provider until the persisted `Retry-After` deadline, or one hour when that header is absent. The menu bar keeps the last verified country (never `Exit IP error`) and the dashboard shows `<provider> paused until …`. The refused request is not retried elsewhere, but the next network change or **Refresh now** runs at once on another provider (`provider_rotated_cooldown`). With every provider paused, `lookup_all_providers_paused` appears and lookups resume at the earliest deadline. |
| UI activation | Open/reopen the dashboard repeatedly: it reads daemon state and spends no provider quota. |
| Network change with no burst tokens | Make more than six network changes over a minute or two, each a few seconds apart (e.g. toggle a proxy or VPN repeatedly). Every change still starts a lookup at once or within its 5-second window; no `refresh_queued` with `reason=burst_budget` and `urgency=network_change` appears. `bash Scripts/check-refresh-log.sh` prints **PASS**. |
| Burst allowance (storm) | Keep a TUN tool flapping continuously for more than 30 seconds. The first ~30 seconds are checked on time. After that, `refresh_queued` with `reason=burst_budget` and `urgency=follow_up` appears and lookups settle to about one per 2 minutes, with the final state still checked. A fresh change after the storm runs at once and logs `refresh_queue_superseded` for the pending follow-up. |
| Daily budget | When a provider reaches 80% of its documented daily limit, `provider_rotated_daily_budget` shows rotation skipping it; if every provider is exhausted, `lookup_daily_budget_exhausted` pauses lookups until 00:00 UTC. |
| Provider rotation | Refresh repeatedly until each pool provider has answered. Every `lookup_succeeded` logs a two-letter country code (never `--`), the flag renders correctly for each, and same-country results never show a country-change banner. The Settings health panel updates attempt, success, failure, and daily-call data; **Test** bypasses the spacing gate and checks exactly that provider; for a paused or budget-exhausted provider it logs `provider_test_skipped` and calls nothing (no other provider is tried instead). IPinfo Lite's **Test** button is disabled until the daemon has a shared token. |
| Provider diagnostics | Use the Settings **Diagnostics** section to keep IPs redacted by default and choose 1, 7, or 30-day log retention. Run `bash Scripts/check-signed-build.sh` against the built app to inspect signing, App Group, and embedded widget-extension status. |
| Debug simulations | In a DEBUG build, run each Settings simulation for transport failure, malformed response, rate limit, country disagreement, and exit IP not on the allowlist; verify the corresponding UI/log state (for example, the allowlist simulation shows the orange **Exit IP not on the allowlist** notice while the menu bar keeps the country with a red stop icon beside it and the Dock shows only the red stop icon), then clear it. Clearing re-evaluates the real allowlist state. |
| Allowlist warning | Add an address that differs from the current exit IP. The **Exit IP Not Allowed** window opens once (`allowlist_warning_presented`), the dashboard show the orange notice, and the menu bar still shows the country (never `Exit IP error`) with a red stop icon beside it, while the Dock icon is only the red stop icon. Refreshing with the same IP does not reopen the window. Add the current IP or empty the list; the window closes, and the notice and the red stop icon disappear (`allowlist_warning_cleared`). The connection is never blocked. |
| Tailscale → Clash Verge provider | Enable it after service setup. Verify Direct → Reject → Direct across native Tailscale reconnect, unchanged endpoint/profile format, routed utun ownership, multi-session candidate selection and no extra persistent process. A stale check returns Reject after 12 seconds; stopping the entire daemon makes the endpoint unavailable. A busy port produces an error and recovers when freed without terminating its owner. |
| Clean uninstall and reinstall | Run installer and daemon suites, then validate live removal across two logged-in accounts. No installed client or service may remain; root state, credentials, personal profiles and logs must survive. Reinstall must reuse settings/budgets. In-place failed repair restores the old executable and plist; abrupt interruption retains recovery files. |
| Missing Tailscale or Clash Verge Rev | `bash Tests/ExitIPDaemonTests/run.sh` covers both with stubs: the preflight's four combinations, and a missing CLI makes the monitor write `tailscale-not-installed` without running `route`, `ifconfig`, or `sudo`. `xcrun swift test` checks every reason's plain words. On a Mac without Tailscale the dashboard reads **Reject · Tailscale isn't installed** and the Event Log one `Tailscale provider · Reject (Tailscale isn't installed)` line; without Clash Verge Rev the **Clash Verge** row and **Apply in Clash Verge** say to install it. |
| Event Log | **Event Log…** in Monitoring opens **Exit IP Event Log**: one line per important event, UTC times, newest last. **Refresh now** adds `Check · Refresh now · …` then `Lookup OK · …` live; toggling Wi-Fi or a proxy adds `Check · network settings changed` or `route changed`. With Tailscale steady for minutes, no new Tailscale lines appear; a Disconnect/Connect adds exactly one `Tailscale provider · Reject (…)` and one `Tailscale provider · Direct utun7`. **Copy All** copies the lines; **Show Log Files** opens the Logs folder. |
| Error stop icon | Run the DEBUG transport-failure simulation: the menu bar, Dock, and dashboard header show the red stop icon instead of the flag, and the widget shows it in its error placeholder. Clearing restores the flag after the next successful lookup. |
| Dashboard service/provider groups | Check disconnected, installation/cancellation/error, connected-uninitialized and initialized states. One-time settings import requires admin authorization. The optional provider toggle and status are separate from service installation; profile editing remains available throughout. Validate narrow/light/dark layouts and retained unsaved proxy edits. |
| Clash Verge profile | With or without the daemon installed, enter a proxy in **Clash Verge profile** (try an invalid port: an orange message, nothing saved), then **Save**. The file `~/Library/Application Support/ExitIPMonitor/clash-verge-profile.yaml` is mode 0600 and contains `udp: true` on the configured proxy (SOCKS5 or HTTP) and the `TS-NATIVE` payload; the log shows `clash_profile_written` with no proxy details, and relaunching makes no Keychain read until the dashboard opens. Opening the dashboard fills the form by itself (one read per session, with the window responsive during a Keychain prompt); **Load proxy info** reads again. The buttons read **Load proxy info**, **Save**, and **Remove**. **Finder** selects `Exit IP Monitor <today> (n).yaml` (0600, identical to the profile file), with `n` past every name in Clash Verge. Clicking again before dragging keeps the name. Dragging it onto Clash Verge → Profiles adds a **Local** profile of that name without changing the active one; the next **Finder** gives `(n+1)` and deletes the old copy. Following **Apply in Clash Verge** (then right-click → Select), `TS-NATIVE` is `Direct` on the routed utun and `MATCH,Proxy` traffic leaves through the proxy. **Remove** deletes the Keychain entry, the file, and the copy. |
| Liquid Glass accessibility | On macOS 26+, check light/dark appearance plus Reduce Transparency, Increase Contrast, and Reduce Motion. Standard controls and `GroupBox` retain a coherent system appearance without custom glass overlays. |
| Build preflight | `bash Scripts/check-build-environment.sh` reports no failures; `bash Scripts/check-build-environment.sh --test` completes the shared-core tests and the daemon script tests on the build Mac. |

Run portable shared-core tests from the **source-kit root**, not from Downloads, not from `XcodeProject`, and not from a folder containing only a copied script:

```bash
cd "$KIT_ROOT"
xcrun swift test --verbose 2>&1 | tee swift-test.log
```

The test package deliberately builds only `Sources/ExitIPShared` and `Tests/ExitIPSharedTests`; it does **not** build the SwiftUI app or WidgetKit extension. `RefreshScenarioTests` runs the real shared refresh policy (`EventRefreshWindow`, `RefreshGate`, `LookupBudget`, `PendingRefresh`) on a virtual clock the way `PublicIPMonitor` wires it. The scenarios include a replay of real logged network events, an empty burst bucket, a VPN connect, settings changed seconds apart, an hour-long event storm, all-day flapping against the daily budgets, and queue superseding.

`bash Tests/ExitIPDaemonTests/run.sh` also checks stalled HTTP clients: it holds the input pipe open and uses a monotonic deadline to verify that the responder exits without sending bytes after the read timeout, before or during the request line and during headers. It also checks disconnected clients with incomplete requests. It times the responder itself, avoiding the sleeping-writer pipeline and rounded wall-clock comparison that caused a false failure on the release runner.

To check a running app end to end, make some network changes and then verify the runtime log:

```bash
bash Scripts/check-refresh-log.sh                       # newest log
bash Scripts/check-refresh-log.sh --since 2026-10-03T12:00:00Z path/to/runtime.jsonl
```

It exits non-zero and lists each network trigger (`network_path`, `network_configuration`, `route_change`, `system_wake`) that did not start a lookup within 2 seconds (8 seconds for a merged or in-flight event), and each network change queued for the burst budget. A network change is excused only when every enabled provider was paused or out of daily budget (`lookup_all_providers_paused`, `lookup_daily_budget_exhausted`); a single paused provider is not, because rotation should have moved to another. If it fails, the first line containing `error:` in `swift-test.log` is the diagnostic to act on. The trailing `error: Build failed` and `fatalError` lines are only SwiftPM summaries and do not identify the cause.

After creating the Xcode project at the specified location, build its scheme with:

```bash
cd "$KIT_ROOT"
xcodebuild \
  -project XcodeProject/ExitIPMonitor.xcodeproj \
  -scheme ExitIPMonitor \
  -destination 'platform=macOS' \
  build
```

## Sources

- Apple: [MenuBarExtra](https://developer.apple.com/documentation/swiftui/menubarextra) (macOS 13+)
- Apple: [Control Center API](https://developer.apple.com/documentation/widgetkit/controlcenter) (macOS 26+)
- Apple: [Creating controls across the system](https://developer.apple.com/documentation/widgetkit/creating-controls-to-perform-actions-across-the-system)
- Apple: [Keeping a widget up to date](https://developer.apple.com/documentation/widgetkit/keeping-a-widget-up-to-date)
- Apple: [Configuring App Groups](https://developer.apple.com/documentation/xcode/configuring-app-groups)
- Apple: [Session activation notification](https://developer.apple.com/documentation/appkit/nsworkspace/sessiondidbecomeactivenotification)
- Apple: [Screen wake notification](https://developer.apple.com/documentation/appkit/nsworkspace/screensdidwakenotification)
- Apple: [Application activation callback](https://developer.apple.com/documentation/appkit/nsapplicationdelegate/applicationdidbecomeactive(_:))
- Apple: [Service Management login items](https://developer.apple.com/documentation/servicemanagement/smappservice)
- Apple: [Installing the command-line tools](https://developer.apple.com/documentation/xcode/installing-the-command-line-tools)
- Apple: [Xcode system requirements](https://developer.apple.com/xcode/system-requirements/)
- Swift.org: [Install Swift on macOS](https://www.swift.org/install/macos/)
- Apple: [Liquid Glass overview](https://developer.apple.com/documentation/technologyoverviews/liquid-glass)
- Apple: [Adopting Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass)
- Apple: [Liquid Glass materials guidance](https://developer.apple.com/design/human-interface-guidelines/materials)
- [IPinfo Lite API](https://ipinfo.io/developers/lite-api)
- [ipapi.co API](https://ipapi.co/api/)
- [IPWHOIS.io API](https://ipwhois.io/documentation)
- [WhatIsMyIP.com API](https://www.whatismyip.com/api/)
- [WhatIsMyIPAddress.com API policy](https://whatismyipaddress.com/api)
- [ip-api.com API](https://ip-api.com/docs/api:json)
