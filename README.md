# Exit IP Monitor for macOS

A native **SwiftUI + WidgetKit** implementation kit for showing the current public exit IP's country in the macOS menu bar, plus richer details in a desktop/Notification Center widget and dashboard.

> **Platform boundary:** macOS Control Center supports third-party Control Widgets on **macOS 26+**, but Apple renders them as system-managed buttons/toggles rather than fully custom multi-line widgets. The tile can show a compact data-dense title, and at larger sizes the system shows title/value information. The richer multi-line inspection view belongs in the medium desktop/Notification Center widget and dashboard. On older macOS versions, the menu bar and WidgetKit widget remain the appropriate system surfaces.

## Install

Exit IP Monitor runs on macOS 14 or later, on Apple silicon or Intel; the Control Center control needs macOS 26. Install it with [Homebrew](https://brew.sh):

```sh
brew install --cask jxz345/tap/exit-ip-monitor
open /Applications/ExitIPMonitor.app
```

The country flag stays in the menu bar while the app runs. Click it to open or restore the dashboard directly. The dashboard is a regular window in Mission Control and App Exposé, with a Dock icon and Cmd-Tab entry while open (including when minimized). That Dock and Cmd-Tab icon is the menu-bar icon itself: the same flag, stop symbol or change highlight, updated whenever the menu bar changes. Closing the dashboard, with its close button, ⌘W or **⌘Q**, hides the Dock icon and leaves monitoring running. Quit with **Quit Exit IP** in the dashboard or the app menu's **Quit Exit IP Monitor**. Settings and Event Log do not keep the Dock icon visible. The window remembers its size and position, and recovers onto a connected display if needed. It also opens on first launch and when you reopen the running app. The cask lives in [jxz345/homebrew-tap](https://github.com/jxz345/homebrew-tap). It installs `ExitIPMonitor-<version>.zip` from this repository's [releases](https://github.com/jxz345/exit-ip-widget/releases) after checking its SHA-256.

Only one copy runs at a time. Normal reopening shows the existing dashboard. A second copy
started directly, including a development build, exits before starting monitoring and asks
the existing app to reopen. A kernel-held instance lock prevents simultaneous startup races
and is released automatically when the owner exits or crashes. Launch Services also rejects
forced multiple instances through `LSMultipleInstancesProhibited` ([Apple documentation](https://developer.apple.com/library/archive/documentation/General/Reference/InfoPlistKeyReference/Articles/LaunchServicesKeys.html#//apple_ref/doc/uid/20001431-113253)).

Homebrew asks for your password once to set up the
[Tailscale → Clash Verge provider](#tailscale--clash-verge-provider-root-daemon), a
LaunchDaemon that survives restarts. Upgrades and reinstalls set it up again, and
`brew uninstall` removes it without a password. Exit IP monitoring works without it. A
cancelled password or failed setup still leaves the app installed and monitoring, and the
dashboard then offers **Install Provider**. `daemon.sh remove` turns it off and keeps it off.
Before moving the app into place, the cask verifies its signature and removes its download
quarantine, so the first launch needs no **Open Anyway** approval. See [First launch](#first-launch).

The current release is **v2.0 (build 10)**, built and tested on a Mac without GitHub Actions
(see [Publishing a release](#publishing-a-release)). Opening the dashboard reads your proxy
info from the Keychain once per app session, in the background, so the Clash Verge profile
form shows it without a click. Startup and automatic refresh read no Keychain, and the IPinfo
token is read only when you load or save it. Launch at login is remembered and restored at the
next launch if macOS dropped it. Existing installations retain cached uninstall hooks; follow
[Clean uninstall and reinstall](#clean-uninstall-and-reinstall) when migrating them.

Earlier installs stalled before startup until the Mac restarted. The cause was a macOS approval
that macOS itself had parked, not the app. A restart released the parked approval; locking and
unlocking the screen does the same within seconds. See
[installation history and root cause](#installation-history-and-root-cause).

| Task | Command |
| --- | --- |
| Update | `brew upgrade --cask jxz345/tap/exit-ip-monitor` |
| Reinstall the same version (for example over the first 1.0 build) | `rm -f "$(brew --cache --cask jxz345/tap/exit-ip-monitor)" && brew reinstall --cask jxz345/tap/exit-ip-monitor` |
| Uninstall (verifies app and daemon cleanup using the existing removal grant) | `brew uninstall --cask jxz345/tap/exit-ip-monitor` |
| Uninstall and also remove settings and logs | `brew uninstall --zap --cask jxz345/tap/exit-ip-monitor` |
| Turn the daemon off (stays off across reinstalls) | `sudo /bin/bash /Applications/ExitIPMonitor.app/Contents/Resources/daemon.sh remove` |
| Turn it back on | `sudo /bin/bash /Applications/ExitIPMonitor.app/Contents/Resources/daemon.sh install` |

2.0 is a normal Homebrew upgrade from any 1.0 build: `brew upgrade --cask jxz345/tap/exit-ip-monitor`. It asks for your password once, for the provider. A Mac with the first 2.0 upload (build 9) needs the reinstall command above, because build 10 replaced it in place. The v1.0 release was replaced in place several times (last with build 8). Homebrew doesn't offer a same-version rebuild as an upgrade, so the reinstall command above, which removes the cached download first, is only needed to repeat a same-version install.

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

Reinstall means **clean uninstall → install**: the app first, then the provider, with one
password prompt. The updated cask first requests
normal Quit, then runs an external cleanup helper even if the app never reached startup.
The helper matches the target executable and owner, including a verified App Translocation
copy. It rechecks each PID's identity before TERM, waits five seconds, then uses KILL for
survivors and waits another five seconds. Unrelated copies are left alone. Inspection
errors, surviving processes and respawning cause failure instead of a false success.

Both provider jobs must unload and their workers exit before cleanup deletes their system
files and, last, their removal grant. The helper uses the existing restricted `sudo -n`
grant; it never requests a password or creates a grant. A missing grant or failed cleanup
stops replacement and prints a recovery instruction. Settings, Keychain credentials, profiles
and logs are retained. Only an explicit `--zap` removes user data.

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

The package preinstall uses helpers carried in the new package; `install.sh` uses the new,
verified app's helper before removing the old bundle. Neither sets up the provider; use
**Install Provider** in the dashboard.
With an existing provider and no usable removal grant, use the printed explicit removal
command and retry. The app remains available when cleanup fails.

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

### What the downloaded build can't do

The release has no Apple developer team, so it can't use an App Group; only a team provisioning profile authorizes one.

- The menu-bar app, dashboard, settings, and allowlist warning work fully. The app runs unsandboxed and keeps its data in `~/Library/Preferences` and `~/Library/Application Support/ExitIPMonitor`.
- The **desktop widget** and **Control Center control** run sandboxed and can't read that data, so they have nothing to show.

To get the widget and control working, [build from source](#start-here-get-the-source) with `--signed-build`, your Team ID, and a registered App Group.

## Liquid Glass conformance

The implementation follows Apple’s Liquid Glass guidance for macOS 26+ without forcing a visual effect into the content layer:

- **Standard system controls first:** the native `NSStatusItem` and dashboard window, plus SwiftUI `Form`, `GroupBox`, `Button`, `Picker`, `Toggle`, `WidgetKit`, and `ControlWidgetButton`, follow platform appearance and accessibility settings.
- **No imitation glass:** The dashboard’s former custom-colored details card is now a standard `GroupBox`. The code deliberately avoids applying `glassEffect` to content cards, because Apple reserves Liquid Glass for the functional controls/navigation layer and recommends standard materials within content.
- **Meaningful color only:** yellow remains limited to the confirmed country-change status. System semantic colors provide the rest of the hierarchy, preserving legibility in light mode, dark mode, Increased Contrast, and Reduce Transparency.
- **Accessibility-friendly behavior:** the app uses native controls and avoids custom motion, so system Reduce Motion and transparency settings remain authoritative. Validate the finished Xcode build with those settings enabled before release.

## What is implemented

| Surface | Behavior |
| --- | --- |
| **Menu bar** | Defaults to the compact **color flag**. Settings offers **country name**, **country code**, **color flag**, or **flag + country name**. It shows no IP or provider information in the resting state. |
| **Single instance** | Normal reopening shows the existing dashboard. Duplicate executable launches exit before startup and request that the existing app reopen. An atomic process-lifetime lock covers concurrent starts and releases on exit or crash; Launch Services also prohibits multiple instances. A running older release is respected during development. |
| **Change attention** | A country change is first confirmed by a **different documented API**. Only then does it trigger a change dot, bold label, accessible announcement, and a visible yellow **dashboard and widget** banner for **10 minutes**. The menu-bar label retains its country-change emphasis; the dashboard and widget show a yellow notice. The person can dismiss the current alert or permanently turn off future highlights in the dashboard or Settings. Changing IP while keeping the same country does not trigger the alert. |
| **Error state** | A failed lookup shows a clear error and hides country name/flag across the menu bar, dashboard, widget, and Control Center, showing a **stop icon** (`xmark.octagon.fill`) where the flag would be: the menu bar shows the icon (with "Exit IP error" for the text styles), the dashboard header show it in red, and the widget and Control Center use it too. Control Center keeps the triangle only for a confirmed country change. **Clear error** removes the message but keeps location hidden until a successful lookup restores it. Provider country codes are validated or resolved from a known country name before a snapshot is stored. |
| **Desktop / Notification Center widget** | Small: flag, country code/name, age. **Medium (recommended for quick inspection):** country, IP, city/region when supplied, organization, relative update time, stale marker, and country-change banner — all without opening the app. |
| **Control Center (macOS 26+)** | A resizable `ControlWidgetButton` shows a compact title in the form **`JP · 203.0.113.8 · 1:45 PM`** (with ` · stale` appended when the data is older than twice the refresh interval) plus an alert symbol after a confirmed country change or while the location is hidden by an error. Resize the tile in Control Center for the system to expose more title/value space. Tapping opens the dashboard, but the country code, current public IP, and last-update time are visible without opening it. |
| **Dashboard window** | The persistent menu-bar flag opens the single retained dashboard directly. A normal titled, resizable primary window participates in Mission Control, App Exposé, Cmd-Tab, full screen, and window cycling. The Dock icon remains while the dashboard is open or minimized and disappears when it closes, even if Settings or Event Log remain open; monitoring continues. That Dock and Cmd-Tab icon is the menu-bar label itself (`DockIconController` renders the same `MenuBarCountryLabel` at the same moment): the flag or chosen text style, the stale prefix, the stop symbol after a failed lookup, and the country-change highlight. It is re-rendered only when what it shows changes, colored for the system appearance. Reopening brings the same window onto the active desktop, restores its remembered frame, and repeats focus after the Dock transition; disconnected displays are handled. Default size is 1000 × 860, clamped to the display. Two columns become one below 960 points, preserving unsaved profile edits; content scrolls and the footer stays available. The left column contains current exit IP, country, location, network, timezone, update time/age, source, the allowlist, and the Clash Verge profile editor. The right contains Monitoring, provider setup/status, and Apply in Clash Verge. Profile fields use full-width label/value rows. Buttons use consistent native regular sizing, minimum widths, and equal widths for paired actions; icon-only removal controls have accessible labels and tooltips. File/URL rows show a single truncated value with its full tooltip and aligned actions beneath. Monitoring shows schedule, highlights, provider order/health/daily budgets, login control, Edit in Settings, and Event Log. Event Log shows the last 500 important UTC-stamped events, updates live, and offers Copy All and Show Log Files. Missing Clash Verge has an installation note; installed Clash Verge has one **Open Clash Verge** action, next to the import steps in Apply in Clash Verge. The proxy-info buttons **Load proxy info**, **Save** and **Remove** share one row. Stale data, country changes, and errors remain visible, with Refresh now, Dismiss, Turn Off Highlights, and Clear error actions. The footer offers Settings, Clear indicators, Quit Exit IP, and monitoring status. |
| **Menu-bar interaction** | The status item remains present with or without windows and updates its flag/name, error symbol, stale marker, and country-change highlight. Clicking opens the dashboard without a popup. Standard app menus provide Settings (Cmd-,), Close Window (Cmd-W), Dashboard (Cmd-1), Minimize (Cmd-M), editing commands, and Quit Exit IP Monitor (no shortcut). **Cmd-Q closes the app's windows instead of quitting**, so the menu-bar app keeps monitoring. Quit Apple Events (Homebrew, logout, `osascript`) still quit. |
| **Dashboard daemon installation** | Homebrew sets the provider up at install. When it is absent, the dashboard shows it as optional with a visible administrator-authentication explanation. That happens after a cancelled or failed cask setup, after opt-out, or after a package or script install. Exit IP monitoring works without it. Incomplete provider setup is visible, with **Install Provider** or **Retry Installation**. Native macOS authentication runs the bundled installer, off the main thread. Both services must be loaded before success. Cancellation and errors remain visible; the setup output is saved to `Logs/daemon-setup-*.log`. Profile editing and import instructions remain available throughout; no app restart is needed after setup. |
| **Installation diagnostics** | Checksum and strict signature verification, timestamped installer and daemon logs, main-thread launch readiness with PID/path/build validation, bounded command execution, and process samples. Optional external `--trace` starts before launch and records Gatekeeper/authentication decisions at information level, code identities, startup records, a concise result summary and incomplete-evidence notices. Early samples survive cancellation; startup observations and app-associated pending evaluations are reported separately from the command result. Collectors stop on every exit path. A blocked-before-entry result also names the recovery for an approval macOS parked: lock and unlock the screen. External cleanup logs record process termination and verified provider removal before uninstall/reinstall; cleanup failures abort replacement. |
| **Settings window** | Opened from the app menu (Cmd-,) or the **Settings** button in the dashboard; a retained AppKit window (like the dashboard) so it reliably comes to the front, at about 560 × 700 on the screen with the pointer (smaller screens get a window that fits). Sections: **Menu bar** display style, **Change attention** highlights, **Startup** (Launch at login + Open Login Items Settings), **Refresh** frequency, **IP location service** (provider pool, per-provider health and a **Test** action that checks exactly that provider—skipped, not redirected, while it is paused or out of daily budget, IPinfo Lite token controls with explicit **Load saved token**, **Save token**, and **Remove token**; IPinfo is skipped until a token is loaded or saved for the session), and **Diagnostics** (clear indicators, redacted logs with configurable retention). Debug builds also expose in-memory failure simulations for manual QA. |
| **Exit-IP allowlist warning** | The dashboard holds exact IPv4/IPv6 addresses you expect to exit from (empty list = no warnings). When a fresh, successful lookup returns an address outside the list, an **Exit IP Not Allowed** warning window opens once per address, and the dashboard show an orange **Exit IP not on the allowlist** notice. The app **only warns**: it never blocks or changes networking, and the menu bar keeps showing the country. Failed lookups never warn. See [allowlist details](#exit-ip-allowlist-warning). |
| **Tailscale → Clash Verge provider (root daemon)** | For Clash Verge Rev (Mihomo) next to the native Tailscale client: keeps one proxy-provider member, `TS-NATIVE`, bound to the current, verified Tailscale `utunN` and serves it at `http://127.0.0.1:18766/provider.yaml`, so a reconnect that renumbers the tunnel needs no profile reload. **Set up by `brew install`, `upgrade` and `reinstall`** with one password prompt, skipped after opt-out. A cancelled password or a failure never fails the app install. It can also be set up by the dashboard’s **Install Provider** action or an explicit `sudo /bin/bash …/daemon.sh install`. Install stops whatever else holds the port (a launchd job is disabled so it stays off). If explicitly installed without Tailscale or Clash Verge Rev, setup prints which app is missing, the provider serves Reject with a [plain-language reason](#reasons) (**Reject · Tailscale isn't installed**), and the dashboard's **Clash Verge** row says when nothing uses the provider. A **removal grant** in `/etc/sudoers.d/` lets `brew uninstall` remove the daemon without a password; it allows only unloading the two jobs, restarting the monitor, and deleting the daemon's files and the grant. `daemon.sh remove` turns the daemon off and writes its opt-out marker; Homebrew installs, upgrades and reinstalls then skip it until an explicit `install`. A root monitor checks the route to `100.100.100.100`, the Tailscale CLI's address (run as the console user), and interface ownership every 2 seconds and writes `provider.yaml`. A launchd-held loopback socket serves that file as `nobody`, closes stalled or incomplete HTTP requests without a response, and serves Reject whenever Tailscale can't be verified or the last check is more than 12 seconds old. The dashboard shows its status in plain words, the file's location (**Open File**, **Show in Finder**), the address it is served at (**Open in Browser**), and whether Clash Verge Rev is installed (status only; **Open Clash Verge** is in Apply in Clash Verge). The dashboard's **Clash Verge profile** group takes your proxy (server, port, username, password; kept in the Keychain). The app writes a complete Clash Verge profile with it, including the provider, to `~/Library/Application Support/ExitIPMonitor/clash-verge-profile.yaml` (0600; never committed or logged; no installer writes it). It shows the file's location (**Open File**, **Show in Finder**) and how to import it into Clash Verge as its one Local profile. See [Tailscale → Clash Verge provider](#tailscale--clash-verge-provider-root-daemon). |
| **Refresh engine** | Checks immediately on launch when an enabled provider is eligible; IPinfo waits for an explicitly loaded or saved session token; offers an opt-in **Launch at login** setting (in the dashboard's Monitoring group and Settings → Startup) that is remembered and re-applied at every launch (`LoginItemPolicy`; a registration macOS dropped is restored, and an earlier registration is adopted); refreshes after any network-environment change (gateway/default route, routing table including TUN split routes, interface or address, proxy, DNS, VPN/tunnel), system wake, screen wake, session activation, and app activation; supports explicit **Refresh now** buttons; uses a true 15-minute default cadence; persists the last successful result; and balances promptness against provider quotas with **immediate-then-wait** event handling (the first network/system event is checked at once; further events in the next 5 seconds become one trailing lookup on the next provider in the pool) and a layered [lookup budget](#lookup-budget-prompt-checks-vs-api-limits): a hard five-second gap per provider, a 6-lookup burst allowance refilling one every 2 minutes that throttles only follow-ups (a storm lasting over 30 seconds, retries) and routine triggers—**a real network change is never queued behind it**—freshness skipping for routine triggers, per-provider daily budgets at 80% of documented limits, and cooldowns after rate-limit/quota/auth refusals (a paused provider is skipped by normal rotation; the refused request is never retried elsewhere, and a pause never hides the last verified location). `NWPathMonitor` updates that report an unchanged path are ignored. A newly started lookup supersedes any queued one. |
| **Release packaging (install on another Mac)** | `Scripts/package-release.sh` locally builds a universal (Apple silicon + Intel) Release app, seals it with ad-hoc signing, verifies both architectures and the packaged signature, and writes an app ZIP, `.pkg`, `install.sh`, and `SHA256SUMS`. 2.0 (build 10) is built and published from this Mac without GitHub Actions as the `v2.0` release (build 10 replaced build 9 in place); v1.0 stays as the rollback. The app runs unsandboxed; the sandboxed widget requires a registered App Group to share its data. Before moving the app into place, the Homebrew cask verifies the sealed signature and removes that app's download quarantine, so a Homebrew install opens without **Open Anyway**. After the move, it sets up the provider with one password prompt; a failure there never fails the install. It requires verified process and provider cleanup on uninstall/reinstall. The package and shell installer use the same cleanup before replacement. Provider installation requires the explicit dashboard action. The package and copied apps still need **Open Anyway**: use Touch ID, and lock and unlock the screen if macOS parks the approval. See [Install](#install) and [Publishing a release](#publishing-a-release). |
| **Keychain access** | One Keychain entry holds the Clash Verge proxy info. Opening the dashboard reads it once per app session (`CredentialSession.loadIfNotLoaded`), on a serial background worker, so the form is filled without a click; **Load proxy info** reads it again, **Save** stores it and writes the profile file, and **Remove** deletes it and the generated file. The IPinfo token is read only by its explicit Load or Save. Startup, provider selection, and automatic refresh never read Keychain. The UI distinguishes not loaded, pending, available, missing, and failed; affected controls wait while the rest of the app remains responsive. Loaded tokens stay in memory until quit; existing Keychain identifiers and credentials are preserved. |
| **Privacy and resilience** | The selected provider sees the public IP address. Provider credentials are kept in the macOS Keychain; the widget receives only the non-secret snapshot through the App Group. |

## Exit-IP allowlist warning

The dashboard can hold a list of exact IPv4 or IPv6 addresses you expect your
traffic to exit from. An empty list turns warnings off.

After a fresh, successful lookup returns an address outside the list (or the
list is edited so the current address is no longer included), the app:

- opens an **Exit IP Not Allowed** warning window showing the address, once per
  address (refreshing with the same address does not reopen it); its **Open
  Dashboard** button goes straight to the list;
- shows an orange **Exit IP not on the allowlist** notice in the
  dashboard for as long as the address stays outside the list.

The app **only warns**. It never blocks traffic, edits routes or firewall rules,
or installs a network extension, so it needs no special signing. The warning is
not an exit-IP error: the menu bar, widget, and Control Center keep showing the
verified country. Adding the current address, emptying the list, or a later
lookup that returns an allowed address closes the window and removes the notice.
A failed lookup never opens a warning.

## Tailscale → Clash Verge provider (root daemon)

Clash Verge Rev in TUN mode next to the native Tailscale client must send MagicDNS
(`+.ts.net`, answered by `100.100.100.100`) out through Tailscale's own `utunN`.
macOS can renumber that tunnel when Tailscale reconnects, and a profile that names
the interface then breaks until it is edited and reloaded. This optional daemon
keeps one Mihomo proxy-provider member, `TS-NATIVE`, bound to the current, verified
Tailscale interface. Mihomo polls it every 3 seconds, so reconnects are picked up
with the same core and no reload. The rest of the app works the same without it.

Explicit provider setup creates two LaunchDaemons, installed and removed together by
`Sources/ExitIPDaemon/daemon.sh` (also shipped in the app bundle as
`Contents/Resources/daemon.sh`):

- **Monitor**, `com.example.exitipmonitor.tailscale-verge`, root, kept alive by
  launchd. Every 2 seconds it requires a non-default route to `100.100.100.100` on a
  `utunN`, exactly one CGNAT IPv4 address from the Tailscale CLI, that interface UP
  and owning that address, and a second route check showing the same interface.
  Each command has a 2-second limit. Only the CLI drops privileges: it runs as the
  console user (with that user's groups, which the CLI needs to reach the Tailscale
  client), and with nobody at the console (the login window) the result is Reject.
  `route` and `ifconfig` stay root. Each pass writes two files to
  `/Library/Application Support/ExitIPMonitor/TailscaleVerge/`:
  `provider.yaml`, the exact bytes Clash receives, and `state`.
- **Responder**, `com.example.exitipmonitor.tailscale-verge-http`. launchd owns the
  `127.0.0.1:18766` socket and runs one short `/bin/bash` process per connection, as
  `nobody`. It reads the two files and answers `GET`/`HEAD` for `/provider.yaml` and
  `/status.json` (anything else is 404 or 501). It never runs a command or calls the
  Mihomo controller. It serves `provider.yaml` only while `state` is fresh and agrees
  with it. Otherwise, or when the last check is more than 12 seconds old, it serves
  Reject, so a stalled or stopped monitor turns into Reject rather than a stale tunnel.

The responses match the earlier standalone helper's (identity `tailscale-verge-live-v1`)
byte for byte, with two exceptions. `checked_age_seconds` in `status.json` is whole
seconds. `provider.yaml` is sent as `text/plain; charset=utf-8` rather than
`application/yaml`, so a browser shows it instead of downloading it. Mihomo's HTTP
provider reads only the status code, `ETag`, and body, so the body Clash parses is
unchanged, and a profile that already uses the URL needs no change.

### Install, disable, and rollback

`brew install`, `brew upgrade` and `brew reinstall` run the bundled `daemon.sh install` once with `sudo`, after the app is in place: one password prompt, like Sleepless. The cask skips it while the opt-out marker below exists. Its failure, such as a cancelled password or a busy port, never fails the app install. Reinstall removes the existing provider during cleanup, then sets it up again. Otherwise use **Install Provider** in the dashboard, or run the following explicitly as an administrator (using `/Applications/ExitIPMonitor.app/Contents/Resources/daemon.sh` for an installed copy):

```bash
sudo /bin/bash Sources/ExitIPDaemon/daemon.sh install   # report prerequisites, copy to root-owned files, load both jobs, add the grant
/bin/bash Sources/ExitIPDaemon/daemon.sh status         # no root needed
sudo /bin/bash Sources/ExitIPDaemon/daemon.sh remove    # unload both, delete their files and the grant, keep it off
```

`install` first reports whether Tailscale (`/Applications/Tailscale.app`) and Clash Verge Rev (`/Applications/Clash Verge.app`) are installed. A missing app is never an error: the daemon is installed either way. It then copies `tailscale-verge.sh` to
`/Library/Application Support/ExitIPMonitor/` (root-owned, so launchd never runs code
you can edit) and writes the plists to `/Library/LaunchDaemons/`. Both survive a
restart. It prints the monitor's first check. Before loading the responder, it checks
with `connect()` whether something else already accepts connections on
`127.0.0.1:18766` (a `bind()` test can succeed over another process's wildcard
listener on macOS), and **stops whatever holds the port**:

- A process that is the main process of a launchd job (for example the earlier
  standalone helper, `gui/<uid>/local.tailscale-verge.live-provider`) has its job
  **disabled and booted out**, so neither KeepAlive, the next login, nor a restart
  starts it again. The output names the job and the command that allows it again
  (`sudo launchctl enable <domain>/<label>`). A process that only inherited a job's
  name from its parent is not treated as that job.
- Any other process gets `TERM`, then `KILL` after 5 seconds.
- Apple's own jobs (`com.apple.*`) are never stopped. If the port is still in use,
  `install` keeps the monitor, skips the responder, and exits with status 3.

Explicit provider reinstallation waits for launchd to finish unloading a job before loading it again. App reinstallation unloads it during cleanup; the cask then loads it again after the new app is in place.

After loading the monitor, `install` writes the **removal grant**,
`/etc/sudoers.d/exitipmonitor-tailscale-verge` (root:wheel, 0440, checked with
`visudo -cf` before it is installed), for the user who ran `sudo` (or the console
user). Like Sleepless's grant, it lets the cask's uninstall step run without a
password. It allows exactly these commands, with these arguments:

```text
/bin/launchctl bootout system/com.example.exitipmonitor.tailscale-verge
/bin/launchctl bootout system/com.example.exitipmonitor.tailscale-verge-http
/bin/launchctl kickstart -k system/com.example.exitipmonitor.tailscale-verge
/bin/rm -f /Library/LaunchDaemons/com.example.exitipmonitor.tailscale-verge.plist
/bin/rm -f /Library/LaunchDaemons/com.example.exitipmonitor.tailscale-verge-http.plist
/bin/rm -rf /Library/Application\ Support/ExitIPMonitor
/bin/rm -f /etc/sudoers.d/exitipmonitor-tailscale-verge
```

Nothing can be loaded, started, or written through it. The plists and the script
stay root-owned, so the grant can't change what runs.

To disable the feature, run `remove`. It deletes the jobs, files, and grant, and writes
`~/Library/Application Support/ExitIPMonitor/tailscale-verge-off` (as you, not as
root). While the marker exists, Homebrew installs, upgrades and reinstalls skip provider
setup; explicit `install` (or **Install Provider**) deletes it. With nothing serving, Mihomo keeps its last member until the
feature is installed again. `brew uninstall` removes the daemon through the grant
through the existing grant; if that fails, cleanup stops and prints the explicit `sudo` removal command to finish.
Deleting the app by hand doesn't remove the daemon; run `remove` first. To back out a
daemon change, check out the earlier commit and run `install` again from the project
directory.

### Missing Clash Verge profile and provider controls

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
- your proxy;
- the `tailscale-live` provider below;
- the `Proxy` group (your proxy) and `TS-DIRECT` group;
- the rules: Tailscale ranges, processes, and domains; private ranges; `MATCH,Proxy`.

Opening the dashboard reads the proxy info from the Keychain once per app session, in the
background, fills the form, and brings the file up to date with the current template.
**Load proxy info** reads it again. Only a successful load or **Save** updates the file;
startup and automatic refresh do not access Keychain. Failed reads leave the existing file
unchanged. The app never logs the proxy. Neither
the app nor `daemon.sh` puts anything into Clash Verge. The dashboard's **Apply in
Clash Verge** group lists these steps (labels as Clash Verge Rev shows them), with an
**Open Clash Verge** button that only launches it:

1. **Save** writes the profile file.
2. In Clash Verge: **Profiles** → **New**. In **Create Profile**, set Type to
   **Local**, click **Choose File**, and pick `clash-verge-profile.yaml`. Then click
   **Save**.
3. Right-click the new profile → **Select**, to make it the active profile. Clash
   Verge reloads once.
4. Check **Proxies** → **Proxy Provider** → `tailscale-live` lists `TS-NATIVE`. The
   dashboard's Tailscale status should read **Direct**.

Clash Verge copies the file when you import it, so import it again after changing the
proxy in the dashboard. Tailscale changes need nothing: they arrive through the
provider every 3 seconds. The **provider file** itself
(`/Library/Application Support/ExitIPMonitor/TailscaleVerge/provider.yaml`) is never
imported. The profile's `tailscale-live` entry fetches it from
`http://127.0.0.1:18766/provider.yaml`.

**Remove** in the dashboard deletes the proxy info from the Keychain and the generated file; the profile
Clash Verge imported is its own copy. Never commit real proxy addresses or
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
installed. The dashboard reads the files every 2 seconds while open and never contacts
the daemon.

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
State changes are logged to the unified log with the tag `exitip-tailscale-verge`:

```bash
log show --last 1h --info --predicate 'eventMessage CONTAINS "exitip-tailscale-verge"'
```

### Timing and limits

- Updates take a few seconds: up to one 2-second check plus one 3-second provider
  refresh. This is automatic recovery, not zero interruption. New connections use
  the current member; existing long-lived connections cannot move to a new tunnel.
- When the responder itself is not running (after `remove`, or while Mihomo starts
  before the first refresh), Mihomo keeps its previous member. Don't treat `payload`
  or `empty-fallback` as an expiry mechanism.
- The CLI path is fixed to the standalone app,
  `/Applications/Tailscale.app/Contents/MacOS/Tailscale`. The port, poll interval, and
  freshness limit are fixed too; there is no configuration file.
- launchd's `inetdCompatibility` mode, which runs one responder per connection, is
  documented as one to avoid for new projects. macOS 27's own `sshd` job still uses it.
  At Mihomo's 3-second interval that is one short process every 3 seconds.
- The monitor runs `sudo -u` for the CLI every 2 seconds. Where sudo logs each
  command, expect one log line per check.
- The first run of a newly installed or updated Tailscale app can take longer than
  the 2-second limit while macOS checks it; that check reports `tailscale-cli-timeout`
  and the next one recovers.
- This is not a tailnet kill switch: traffic outside Mihomo's TUN still follows
  native routing.

## Refresh recommendation

| Approach | Tradeoffs | Cost | Setup complexity |
| --- | --- | --- | --- |
| **On-demand + network-change check, 30 minutes** | Lowest traffic and battery impact; slower to notice a changed VPN/exit route that does not trigger a network-path event. | Free tiers are ample. | Lowest. |
| **15-minute background refresh (implemented default)** | Detects most VPN, roaming, and public-IP changes promptly. There are about **96 scheduled lookups/day**, plus event checks: each burst of network/lifecycle events costs one immediate lookup and at most one trailing lookup per 5-second window, and a storm lasting over 30 seconds is throttled by the burst allowance (about one lookup per 2 minutes). | Review the selected provider’s terms if the Mac changes routes unusually often. | Low. |
| **5-minute refresh** | About **288 lookups/day**; more battery/network work and more likely to hit a service quota. Use only for frequent, short-lived VPN routing changes. | Prefer an unlimited or paid plan. | Low, but needs provider capacity. |

The default is deliberately **15 minutes**, plus event-driven checks. The periodic trigger runs in the main run loop’s common mode and uses a forced refresh, so menu tracking or a slight timer offset cannot silently turn a 15-minute selection into a 30-minute cadence. Every non-startup primary lookup attempt—periodic, manual, network, wake, or session/display event—respects a persisted **five-second minimum interval per provider**; startup intentionally bypasses it once. A request that would hit a provider called less than five seconds ago goes to the next eligible provider in the pool instead, and is queued only when every enabled provider was called within the last five seconds. On top of that gate, the [lookup budget](#lookup-budget-prompt-checks-vs-api-limits) caps follow-up and routine lookups and per-provider daily usage. It never delays the check for a real network change. The widget itself does **not** perform web requests: the app requests an immediate WidgetKit reload only when rendered IP/location/alert content changes, while its timeline refreshes the shared snapshot at most hourly for relative-age freshness.

### Event-driven refresh policy

The menu-bar app registers only documented macOS signals and handles them **immediately first, then waits**:

1. The first event after a quiet period requests a lookup **at once** (no debounce) and opens a **5-second event window**.
2. Network-urgency events (path, SystemConfiguration, routing socket, system wake) that arrive inside the window are merged; when the window ends, **one trailing lookup** checks the settled state (for example, a VPN that finished installing its routes after the first event). The trailing lookup opens its own window, so a continuing storm settles to about one lookup per window.
3. Trailing lookups within **30 seconds** of the leading lookup count as network changes and run on time even when the burst allowance is used up, so settings changed a few seconds apart are each checked within one window. Only a storm that keeps going past 30 seconds (a flapping tunnel) has its further trailing lookups treated as follow-ups, which the burst allowance throttles to about one per 2 minutes. The final state is still checked: a deferred follow-up is queued, never dropped.
4. Routine events (screen wake, session activation, app activation) inside the window are absorbed: the immediate lookup already answers them.
5. Because the five-second gap is per provider, the immediate lookup and the trailing lookup run on **different providers** from the rotation pool, so neither has to wait for the other's gap.
6. A network event that arrives while a lookup is in flight becomes one **recheck** right after that lookup completes, with the event's urgency. A lookup that starts while another is queued (for example, a burst-deferred follow-up) **supersedes** the queued one (`refresh_queue_superseded`), because it already answers it.

| Signal | Mechanism | Behavior |
| --- | --- | --- |
| App launch / login startup | App lifecycle launch; optional `SMAppService.mainApp` login item | Performs the first check immediately, even after a recent persisted attempt. Enable **Launch at login** in Settings to ensure the utility is running at a fresh user login. |
| Network route or interface/settings change | `NWPathMonitor` | Requests a refresh immediately (event window applies). Updates whose status, interfaces, gateways, and address families are identical to the previous path are ignored (`network_path_unchanged`). |
| Proxy, DNS, gateway, service order, VPN/IPSec/PPP, or interface list change | SystemConfiguration dynamic store (`NetworkConfigurationObserver`) | Requests a refresh immediately (event window applies). See [Network, proxy, and tunnel triggers](#network-proxy-and-tunnel-triggers). |
| Kernel routing-table, gateway, address, or interface change | `PF_ROUTE` routing socket (`RouteChangeObserver`) | Catches routes that TUN tools install directly (e.g. split `0/1` + `128/1` default routes on `utun`) without updating SystemConfiguration. Kernel noise—ARP/ND entries, per-connection cloned routes, redirects, lookup misses, and loopback/AWDL/`llw`/`anpi` interfaces—is ignored. Requests a refresh immediately (event window applies). |
| Active provider changed | Settings | Choosing a different **Provider**, or removing the active provider from the pool, requests an immediate check with the newly selected provider. Adding or reordering pool entries takes effect at the next lookup without spending one. |
| IPinfo Lite token loaded or saved | Explicit Settings action | Enables IPinfo for this session and requests a check under the existing refresh rules. Load preserves provider cooldowns; Save clears its authentication pause. Remove requests no check and clears the session token after successful deletion. |
| Mac wakes from sleep | `NSWorkspace.didWakeNotification` | Requests a refresh immediately; later wake and network events in the window become one trailing lookup. |
| Displays wake after sleep/darkness | `NSWorkspace.screensDidWakeNotification` | Requests a refresh immediately, or is absorbed if an event window is already open. |
| User session becomes active again | `NSWorkspace.sessionDidBecomeActiveNotification` | Covers login/session switch-in; requests a refresh immediately, or is absorbed by an open event window. |
| App becomes active | `NSApplicationDelegate.applicationDidBecomeActive(_:)` | Requests a refresh when the person returns to the app, or is absorbed by an open event window. |

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

Refreshes use the enabled ordered pool, which defaults to `ipapi.co`, IPWHOIS.io, and `ipapi.is`. The active provider is persisted in the App Group and advances after a successful result. The five-second gap is tracked **per provider**, so a lookup requested shortly after another (an event's trailing lookup, a second **Refresh now**) runs immediately on the next pool provider that has not been called in the last five seconds (`provider_rotated_spacing`). Temporary transport, malformed-response, and 5xx failures advance to the next eligible provider after a five-second retry delay; a `429`, authentication error (401/402/403), or provider quota message pauses that provider; the refused request is **not** retried on another vendor. Later lookups (the next network event, timer tick, or **Refresh now**) skip the paused provider in normal rotation (`provider_rotated_cooldown`), exactly as they skip a provider whose own daily budget is used up.

When a **successful** primary API lookup reports a different country from the previously verified result, the app makes exactly **one** call to a different documented HTTPS API:

- Primary `ipapi.co`, `ipapi.is`, or IPinfo Lite → confirmation by **IPWHOIS.io**.
- Primary **IPWHOIS.io** → confirmation by `ipapi.co`.
- If both countries agree, the app stores the new result and shows the configured highlight.
- If the result disagrees or the confirmation API is unavailable, the app retains the last verified country and shows an **awaiting confirmation** message. A later scheduled or manual `Refresh now` retries the normal flow.

This is a **data-quality check**, not rate-limit rotation. It never runs after a `429`, failed primary call, or authentication error, so it cannot be used to evade a provider's quota.

### Lookup budget (prompt checks vs. API limits)

A network change should be checked within seconds, but a flapping VPN, a laptop that sleeps and wakes all day, or someone toggling a TUN tool can generate hundreds of events, and the free providers allow only 100–1,000 requests per day. The app therefore classifies every refresh trigger and spends quota in layers (`LookupBudget` in `ExitIPShared`, persisted in the App Group so relaunching never resets it):

| Urgency | Triggers | Policy |
| --- | --- | --- |
| **Manual** | **Refresh now**, provider change, IPinfo token loaded or saved | Never refused by the burst allowance (it still uses a token). Subject only to the per-provider 5-second gap, provider cooldowns, and daily budgets. |
| **Network change** | Launch, network path, SystemConfiguration (proxy/DNS/gateway/VPN/interface), routing socket (routes/TUN), system wake, trailing lookups within 30 s of the leading lookup, a recheck or queued lookup standing in for one of these | Runs **immediately**, never delayed by the burst allowance (it still uses a token, so it counts against later follow-ups). Subject only to the per-provider 5-second gap (which normally just picks the next pool provider), provider cooldowns, and daily budgets. |
| **Follow-up** | Trailing lookups once an event storm has lasted more than 30 s, scheduled retries | Runs while burst tokens remain. When they run out, the check is **deferred, never dropped**: one lookup is queued for when the next token arrives, so the final network state is always checked. |
| **Routine** | Periodic timer, app activation, screen wake, session activation | Skipped while the last successful result is under **2 minutes** old, and dropped (not queued) when no burst token is available. The next timer tick or event covers it. |

The layers, in the order a request meets them:

1. **Provider cooldown:** a provider that refused requests stays paused until its deadline and rotation skips it (see below). Only when every enabled provider is paused or exhausted do lookups wait, until the earliest deadline (`lookup_all_providers_paused`).
2. **Per-provider daily budget:** each provider gets **80%** of its documented free daily limit: ipapi.co 800, IPWHOIS.io 800, ipapi.is 80, IPinfo Lite unlimited. Primary *and* confirmation calls count. The budget resets at **00:00 UTC**. Normal pool rotation skips an exhausted provider. If every enabled provider is exhausted, lookups pause until the reset and the UI shows the pause time. This self-imposed limit keeps the app under each provider's documented free limit; it is never a reaction to a `429`.
3. **Five-second minimum gap per provider** (startup bypasses it once). A request goes to the next pool provider not called in the last five seconds; only when every enabled provider is inside its gap is it queued for the earliest boundary, keeping its urgency. Event-driven requests are additionally shaped by the 5-second [event window](#event-driven-refresh-policy) (immediate lookup, then at most one trailing lookup).
4. **Burst allowance (token bucket):** **6** tokens, refilling **1 every 2 minutes**. Every lookup spends a token, but only follow-ups wait for one and routine checks are dropped without one. Real network changes and manual refreshes always run. A continuous storm therefore costs one leading lookup plus about six trailing lookups in its first 30 seconds, then settles to about one lookup per 2 minutes (≤ 30/hour) instead of one every 5 seconds.

Worst case, a continuous storm is bounded by the refill rate. Distinct network changes (each arriving after the previous event window closed) are each checked at once, so their cost is bounded by the per-provider gap and, ultimately, by each provider's daily budget. Typical use (15-minute timer plus a few network changes) uses roughly 100–150 lookups a day spread across the pool.

### Rate-limit cooldown behavior

A provider is paused when it refuses the client: HTTP `429`; `401`/`402`/`403` (bad or missing credentials, payment required, or a quota block); or a JSON error body that reports a rate or quota limit (for example ipapi.co `"reason": "RateLimited"`). Saving a new IPinfo token clears that provider's pause so the new credential is tried at once. Removing the token also clears the pause but spends no lookup: while IPinfo Lite has no token, rotation skips it (like a paused provider) rather than producing a missing-token error that would hide the location. A saved token is not loaded automatically on relaunch: click **Load saved token** in Settings once per session, or save a new token. Loading preserves any provider cooldown. If IPinfo Lite is the only enabled provider and no token is available in memory, monitoring waits with a Load/Save instruction, keeps the last verified result, and spends no request or quota. Anonymous providers remain eligible in mixed pools.

When a primary or confirmation service sends `429`, the app parses both seconds and HTTP-date `Retry-After` forms when supplied; otherwise it applies a conservative **one-hour** pause. It persists the deadline per provider in the App Group and does not call that provider again until the deadline. The refused request is not retried elsewhere; the next lookup (network event, timer, or **Refresh now**) runs on the next eligible pool provider, as normal rotation would after any lookup. A pause is **not an exit-IP error**: the menu bar, widget, and Control Center keep showing the last verified location, and the dashboard show which provider is paused and until when. Only when every enabled provider is paused or out of daily budget do lookups wait, until the earliest moment one becomes usable. A rate-limited confirmation provider leaves the country change unconfirmed and schedules a later normal check; it is never replaced automatically. Changing to a different provider remains an explicit person-controlled configuration choice.

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
│   ├── ExitIPShared/             # Codable snapshot, shared App Group storage, providers, Keychain helper
│   ├── ExitIPMonitorApp/         # Menu-bar app, monitor, dashboard/views, shared OpenIntent
│   ├── ExitIPMonitorWidgets/     # WidgetKit desktop widget and macOS 26 Control Widget
│   └── ExitIPDaemon/             # Tailscale → Clash Verge root daemon (bash) and its installer
├── Tests/ExitIPSharedTests/      # Portable shared-core tests
├── Tests/ExitIPDaemonTests/      # Bash tests for the daemon scripts (run.sh runs them all)
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
EXIT_IP_CASK_PATH=/opt/homebrew/Library/Taps/jxz345/homebrew-tap/Casks/exit-ip-monitor.rb \
    bash Tests/ExitIPInstallTests/run.sh
bash Tests/ExitIPDaemonTests/run.sh
bash Scripts/package-release.sh
```

`Scripts/package-release.sh` accepts generator options such as `--app-group ID`, builds a
universal ad-hoc signed Release app, verifies the signatures and architectures, and writes:

- `ExitIPMonitor-<version>.zip`, which the Homebrew cask installs. It is created without extended attributes;
- `ExitIPMonitor-<version>.pkg`, the Installer package (scripts in `Scripts/pkg/`);
- `install.sh`, which is `Scripts/install-release.sh` with the repository, version, and package SHA-256 filled in. The repository comes from the `origin` remote, or from `EXIT_IP_RELEASE_REPO=owner/repo`;
- `SHA256SUMS`.

The script warns when the ZIP or package carries AppleDouble metadata. The ZIP must have none (`zipinfo -1 dist/ExitIPMonitor-<version>.zip | grep -c '\._'` prints 0). The package always carries some, because `pkgbuild` stages a re-stamped copy, and the cask doesn't use it. Publishing a new version (2.0 was the first done this way) is a separate manual action:

1. Bump `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` in `Scripts/generate-xcode-project.sh`, add the `CHANGELOG.md` section, and build.
2. **Gate before publishing.** Point the local tap clone's cask at the new ZIP (`version`, `sha256` from `dist/SHA256SUMS`, and a temporary `url "file:///…/dist/ExitIPMonitor-<version>.zip"`). Then run the install matrix in [Maintainer notes](#maintainer-notes-for-the-next-coding-session) with `HOMEBREW_NO_AUTO_UPDATE=1`: upgrade from the installed version, opt-out reinstall, a password reinstall in a real terminal, uninstall, and a fresh install.
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

The running app writes JSON-lines diagnostics to `~/Library/Application Support/ExitIPMonitor/Logs` (one `runtime-<launch time>-<pid>.jsonl` file per launch, so simultaneous launch attempts do not overwrite each other's logs). Set `EXIT_IP_LOG_DIRECTORY` before launching to write runtime logs somewhere else during development; it does not change the instance lock. Before `process_entered`, the app cannot emit runtime events: use the external launch checker's `summary.txt`, security trace and process sample. Its reports and the external cleanup helper’s timestamped TERM/KILL, service-removal, and failure messages are separate from the runtime event stream. No app runtime event is required to stop a pre-entry process. Useful events when checking behavior against this README:

| Event | Meaning |
| --- | --- |
| `process_entered` / `app_initialized` / `application_did_finish_launching` | Startup milestones with PID, launch ID, version and build. |
| `status_item_created` / `status_item_clicked` / `dashboard_presented` / `dashboard_front_requested` / `dashboard_closed` | Menu-bar creation, click delivery, and dashboard foreground/close requests. Closing removes Dock presence without stopping monitoring. The heartbeat reports dashboard open/visible/minimized/key/active-Space state, app activation, Dock visibility, and status-item visibility; a foreground request alone is not proof that the window became key. |
| `duplicate_instance_blocked` / `duplicate_launch_reopened` / `single_instance_lock_failed` | A second process exited before app startup, the existing app received its reopen request, or a filesystem error prevented safe single-instance startup. |
| `startup_services_ready` | Non-credential services initialized. Startup does not access Keychain or rewrite the proxy profile; build 8 no longer emits `startup_profile_begin`. |
| `keychain_operation` | An explicit Load, Save, or Remove begins/completes on the background worker. Fields are `operation`, `outcome`, and `duration_ms`; no account values, credentials, or backend error text. A pending operation can remain unfinished while the main-thread heartbeat continues. |
| `dashboard_presented` / `app_ready` / `app_terminating` | Dashboard shown, main queue responding, and shutdown. `launch_heartbeat_failed` records a diagnostic write failure. |
| `monitor_started` / `monitor_stopped` | IP monitor start and stop. |
| `tailscale_provider_changed` | What the Tailscale → Clash Verge responder serves changed (`served` direct/reject, `interface`, `reason`). Recorded only on a change; the daemon's 2-second rewrites never add a record. The first reading after launch is recorded once. |
| `daemon_install_started` / `daemon_install_succeeded` / `daemon_install_cancelled` / `daemon_install_failed` | Dashboard installation lifecycle, also shown in the Event Log. Includes the local diagnostic log path, never passwords. Success requires both background services loaded. |
| `clash_profile_written` | The app wrote `~/Library/Application Support/ExitIPMonitor/clash-verge-profile.yaml` (`path` only; the proxy is never logged), after the dashboard's automatic load, **Load proxy info**, or **Save**. `clash_profile_write_failed` (`error`) reports a problem. |
| `provider_health_changed` | Provider attempt/success/failure history is persisted for the Settings health panel. |
| `refresh_requested` | A refresh was asked for. `trigger` is `startup`, `manual`, `periodic`, `network_path`, `network_configuration`, `route_change`, `system_wake`, `screens_wake`, `session_active`, `app_active`, `queued`, `trailing`, `retry`, `recheck`, `provider_changed`, or `settings_changed`. `urgency` is `manual`, `network_change`, `follow_up`, or `routine` (see [Lookup budget](#lookup-budget-prompt-checks-vs-api-limits)). |
| `refresh_queued` | The request was deferred; `reason` is `provider_gap` (every enabled provider was called within 5 seconds) or `burst_budget` (no burst token; only ever with `urgency=follow_up`), `urgency` is kept for the queued lookup, and `notBefore` is when the single queued lookup runs. |
| `refresh_queue_superseded` | A lookup started while one was queued; the queued lookup (`notBefore`) was cancelled because the started one answers it. |
| `refresh_skipped` | A routine trigger did not spend a lookup; `reason` is `fresh` (result under 2 minutes old), `burst_budget`, or `event_window` (absorbed by the immediate lookup of an open event window). |
| `refresh_event_merged` | A network event arrived inside an open event window and was merged into the single trailing lookup at `trailingAt`. |
| `network_path_unchanged` | `NWPathMonitor` reported an update with the same status, interfaces, gateways, and address families, so no refresh was requested. |
| `provider_rotated_spacing` | The active provider was called less than 5 seconds ago, so this lookup moved to the next eligible provider (`from`, `to`, `trigger`). |
| `provider_rotated_cooldown` / `lookup_all_providers_paused` | The active provider is paused after refusing requests, so rotation moved on (`from`, `to`, `trigger`); or every enabled provider is paused or exhausted and lookups wait until `resumeAt`. |
| `provider_rotated_daily_budget` / `lookup_daily_budget_exhausted` | The active provider used its daily budget, so rotation moved on; or every enabled provider is exhausted and lookups pause until `resetAt` (00:00 UTC). |
| `refresh_coalesced_in_flight` | A request arrived during a lookup and was folded into one post-lookup recheck, which keeps the highest urgency of the folded requests. |
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
| `ipinfo_token_removed` | The IPinfo Lite token was removed; rotation skips IPinfo Lite until a token is loaded or saved. |
| `indicator_error_set` / `error_cleared` / `country_change_dismissed` | User-visible error and highlight state. |

| Goal | Apple Account / developer team needed? | Result |
| --- | --- | --- |
| Compile and locally inspect the app bundle | **No** | The app bundle is created at the Debug path above and ad-hoc signed. |
| Menu-bar app only, launched locally | **No** | The ad-hoc signed app runs unsandboxed and works from the Debug path above. It is not a sandboxed or notarized installation. |
| Widget, Control Center control, and shared snapshot data | **Yes** | The app and extension need an App Group registered under the same developer team so they can share the stored exit-IP snapshot. |
| Copy the menu-bar app to another Mac | **No** | `brew install --cask jxz345/tap/exit-ip-monitor`, or the release's `.pkg` / `install.sh` from `Scripts/package-release.sh` (ad-hoc signed, universal). A Homebrew install opens without Gatekeeper approval. The package and copied apps need **Open Anyway** ([First launch](#first-launch)). Verify readiness as described in [Install](#install). The widget still needs a registered App Group. |
| Sign, install reliably, or distribute without a Gatekeeper prompt | **Yes** | Supply a real team and registered App Group using `--signed-build`. Notarization is additionally required for distribution outside Homebrew without the **Open Anyway** step. |

Apple documents that an App Group lets an app and its extension share a container and that Xcode retrieves groups from the developer account. Therefore, this project’s full menu-bar + widget + Control Center design cannot be correctly installed without an Apple developer team and a registered App Group. See Apple’s [Configuring app groups](https://developer.apple.com/documentation/xcode/configuring-app-groups).

### Prerequisites

- A **Mac** running a macOS version supported by the selected Xcode. For example, Apple lists **macOS Sequoia 15.6+** for Xcode 26; consult Apple’s current system-requirements table when selecting a newer Xcode release.
- **Full Xcode** with a **macOS 26-or-newer SDK** to compile the Control Center control. The standalone Command Line Tools package does not include `xcodebuild`, so it is not sufficient for this app and its WidgetKit extension.
- macOS 14+ deployment target for the menu-bar app and normal WidgetKit widget.
- macOS 26+ at runtime for the Control Center control.
- For the widget and Control Center control: an Apple developer team with an App Group enabled for both targets. The menu-bar app builds and runs without one.

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

### Create targets

The condensed checklist below is a reference. For a first assembly, use the complete [click-by-click Xcode assembly guide](XCODE_ASSEMBLY.md) instead; it spells out exactly where to save the `.xcodeproj`, which template files to delete, and how to assign every file to each target.

1. In Terminal, while still in `$KIT_ROOT`, create a dedicated location for the Xcode project:

   ```bash
   mkdir -p "$KIT_ROOT/XcodeProject"
   ```

2. In Xcode, choose **File → New → Project → macOS → App**. Name it `ExitIPMonitor`, choose **SwiftUI**, and save the project in **`$KIT_ROOT/XcodeProject`**. This creates `XcodeProject/ExitIPMonitor.xcodeproj` while leaving the authoritative sources in `Sources/` unchanged.
3. Set the app deployment target to **macOS 14.0** (or later) and use an Xcode/macOS 26 SDK.
4. Add a **Widget Extension** named `ExitIPMonitorWidgets`; select **Include Control**. Keep its deployment target at macOS 14+; `ExitIPControl` is guarded with `@available(macOS 26.0, *)`.
5. Replace `group.com.example.exitipmonitor` in all of the following with the registered App Group identifier:
   - `Sources/ExitIPShared/AppGroupIdentifier.swift`
   - `Configuration/ExitIPMonitor.entitlements`
   - `Configuration/ExitIPMonitorWidgets.entitlements`
6. Add the source files from `../Sources/` and configuration files from `../Configuration/` to the Xcode project. **Uncheck “Copy items if needed”** so Xcode references the source-kit files instead of creating a second, diverging copy. Remove the template SwiftUI app files that Xcode created, so only the supplied sources compile.
7. Enable **App Groups** in the Signing & Capabilities tab of **both** targets. Assign the corresponding entitlement files from `../Configuration/`.
8. Set the app’s `Info.plist` to `../Configuration/ExitIPMonitor-Info.plist` (or copy `LSUIElement = YES` into the app’s plist) to make it a menu-bar-first utility without a Dock icon.
9. For a manually assembled project, link **SystemConfiguration.framework** to the **ExitIPMonitor app target**. The automated generator already does this.

### Assign target membership

| Source group | App target | Widget extension target |
| --- | ---:| ---:|
| `Sources/ExitIPShared/*.swift` | Yes | Yes |
| `Sources/ExitIPMonitorApp/ExitIPMonitorApp.swift` | Yes | No |
| `Sources/ExitIPMonitorApp/PublicIPMonitor.swift` | Yes | No |
| `Sources/ExitIPMonitorApp/ExitIPViews.swift` | Yes | No |
| `Sources/ExitIPMonitorApp/NetworkConfigurationObserver.swift` | Yes | No |
| `Sources/ExitIPMonitorApp/ExitIPIntents.swift` | **Yes** | **Yes** |
| `Sources/ExitIPMonitorWidgets/*.swift` | No | Yes |

`ExitIPIntents.swift` must be compiled into **both** targets because Apple's `OpenIntent` flow requires the widget extension and containing app to share the intent definition.

### Initial configuration

1. Run the app and choose the menu-bar item.
2. Open **Settings** from the app menu (Cmd-,) or **Settings** in the dashboard.
3. Choose the menu-bar **Display** mode: `Color flag` (default), `Country name`, `Country code`, or `Flag and country name`. The menu label contains only that country presentation (plus the country-change indicator when applicable), with no extra globe icon.
4. Use **Highlight country changes** to enable/disable all future country-change highlights. A visible alert can also be dismissed individually from the dashboard. With it enabled, a country change must agree with a second documented API before it is highlighted.
5. Enable **Launch at login** in the dashboard's **Monitoring** group, or in the **Startup** section of Settings, if the utility should start and check during a fresh user login. macOS can require approval; use **Open Login Items Settings** if requested. The login item points to the app bundle at its current path, so copy `ExitIPMonitor.app` to `/Applications` and launch it from there before enabling it. A build run from `XcodeProject/DerivedData` is replaced on every `--force` regenerate.
6. Use **Refresh now** in the dashboard whenever an immediate lookup is needed. It runs at once on the next pool provider not called in the last five seconds; only when every enabled provider was called within five seconds does it queue for the earliest boundary.
7. Leave the default provider pool (`ipapi.co`, IPWHOIS.io, `ipapi.is`) for a no-token trial, or add/select **IPinfo Lite** and save a free token (the token field appears whenever IPinfo Lite is in the pool). The token stays in Keychain; after each relaunch click **Load saved token** to make it available to IPinfo for that session. Opening Settings never reads it automatically. The active provider is persisted and advances after every successful lookup, so a relaunch continues from wherever the rotation left off rather than always starting with `ipapi.co`.
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

Changing a gateway, route, interface, system proxy, or enabling/disabling a TUN/VPN therefore requests a refresh **immediately**. Further changes in the next five seconds are merged into one trailing lookup at the end of that window; if the earlier lookup is still in flight then, the trailing check runs right after it completes. Every non-startup source—manual controls, paths, SystemConfiguration notifications, wake, and periodic checks—respects the **hard five-second minimum interval per provider**: a lookup goes to the next pool provider outside its gap, and only when every enabled provider was called in the last five seconds does the UI show the queued time and perform one lookup at the earliest boundary. Successful lookups advance through the enabled provider pool, and temporary failures rotate through each eligible provider before exponential backoff; `429` and authentication failures pause the affected provider, and later lookups skip it in rotation until its deadline.

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
  `must_succeed: false`, inside `unless_path_exists` for the opt-out marker
  `tailscale-verge-off`. The script runs through `/bin/bash` because Homebrew must not execute a
  bundled script directly. A failure, such as a cancelled password or a busy port, leaves a
  working app; the dashboard then offers **Install Provider**.
- **`uninstall`** sends a graceful `quit:` (an AppleEvent), then runs the embedded cleanup helper.
  It must succeed and must not run as root. It removes the provider through the `sudo -n` removal
  grant. The block between `BEGIN/END GENERATED CLEANUP` is generated: run
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
| Failed password | Run from an agent shell: it has no terminal, so `sudo` fails | Install exits 0; the app works; no provider |
| Opt-out | `touch ~/Library/Application Support/ExitIPMonitor/tailscale-verge-off`, reinstall, remove the marker | 0 `sudo:` lines in the output; the app works |
| Password | A person runs the reinstall in a real Terminal window (not a `!` command) | `daemon.sh status` shows both jobs loaded; grant root:wheel 0440; `TailscaleVerge/state` fresh |
| Uninstall | `brew uninstall` from an agent shell | Exit 0 with no password; no app, plists, grant, support folder or workers |
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
| Install on another Mac | Build locally, verify checksums, both architectures and strict signatures, and inspect archives for AppleDouble metadata. With the updated cask, a fresh installation asks for the password once and creates both provider jobs and the grant. A Homebrew install must open without a Gatekeeper dialog and produce a fresh matching heartbeat and a successful lookup. Package and shell installs behave likewise after their approval. A local unquarantined build does not count as a downloaded-app test. |
| Homebrew provider setup | Run `brew install --cask jxz345/tap/exit-ip-monitor` in a terminal. It asks for the password once. `daemon.sh status` lists both jobs as loaded, `/etc/sudoers.d/exitipmonitor-tailscale-verge` is root:wheel 0440, the provider's `status.json` is fresh, and the dashboard shows the provider installed. Cancel the password (or install without a terminal): the install still succeeds, the app opens and completes a lookup, and the dashboard offers **Install Provider**. With `~/Library/Application Support/ExitIPMonitor/tailscale-verge-off` present there is no prompt and no provider. `brew uninstall` asks for no password and leaves no provider jobs, workers, files or grant. Restart: the monitor runs again and `status.json` is fresh. `EXIT_IP_CASK_PATH=<tap>/Casks/exit-ip-monitor.rb bash Tests/ExitIPInstallTests/run.sh` checks the declared steps. |
| Homebrew first launch | Test with an app identity this Mac has never approved, because an approved one opens regardless. Run `brew install --cask jxz345/tap/exit-ip-monitor`, then `brew reinstall`. Both preflight steps pass, and `xattr -lr /Applications/ExitIPMonitor.app \| grep -c com.apple.quarantine` prints 0. After `open` there is no Not Opened or Open Anyway dialog. The runtime log has `app_ready` and `lookup_succeeded`, and `syspolicyd` logs `GK evaluateScanResult: 2` without `Prompt shown`. A bundle that fails `codesign --verify` aborts the install before `/Applications` changes. With an approval parked by an earlier **Use Password** attempt, lock and unlock the screen: `Allowing code due to user override` follows and the waiting app starts. `EXIT_IP_CASK_PATH=<tap>/Casks/exit-ip-monitor.rb bash Tests/ExitIPInstallTests/run.sh` checks the declared steps. |
| First launch and reopen | On a Mac that has never run the app, the first launch opens the dashboard. Quit and relaunch: only the menu-bar item appears. Open the app again from Finder while it runs: the dashboard comes forward. |
| Dock icon matches the menu bar | Open the dashboard: the Dock and Cmd-Tab icon is the menu bar's flag. Switch Settings → Menu bar style (flag → code → name → flag): the Dock follows each change immediately. Disconnect the network until a lookup fails: both show the stop symbol, then the flag again after a successful lookup. A confirmed country change shows the same highlight in both. Switch light/dark: the Dock's text and symbol stay legible. `bash Tests/ExitIPAppTests/run.sh` checks one render per visible change and writes `menubar-*.png` / `dock-*.png` pairs. |
| Cmd-Q keeps the app | With the dashboard (or Settings, Event Log) in front, Cmd-Q closes the windows; the flag, monitoring and process stay (`windows_closed_by_shortcut`). **Quit Exit IP** and the app menu's Quit quit; `brew uninstall` and `osascript -e 'quit app id "com.example.exitipmonitor"'` still quit. |
| Launch at login remembered | Turn Launch at login on, `brew reinstall`, open the app: the setting is still on, and the runtime log shows `login_item_synced` (`register` when macOS had dropped it). Turn it off: the next launch unregisters a leftover. Restart: the app starts at login. |
| Credential access | Launch with saved credentials, open Settings, reopen, and refresh: no `keychain_operation` for the IPinfo token. Opening the dashboard reads the proxy info once per session and fills the form; reopening it doesn't read again. **Load proxy info** populates fields; cancel/deny approval and verify an error with the existing profile unchanged. Hold an approval request open: other controls and launch heartbeats keep responding, and duplicate credential actions are disabled. Load/Save enables IPinfo for this session; Remove stops its use without a lookup. Relaunch returns to not loaded. Run `bash Tests/ExitIPAppTests/run.sh` for isolated fake-backend/provider checks and off-screen control renders, plus the shared credential tests. |
| Launch failure diagnostics | A blocked process without `app_ready`, an old build, an old heartbeat, or another bundle cannot produce success. A failure exits within its deadline and saves app-specific evidence. `bash Tests/ExitIPInstallTests/run.sh` passes. |
| First launch | Menu label changes from `Locating` to the selected country display after an immediate check. Dashboard shows public IP, provider data, absolute **Last updated** time, and relative age. |
| Menu settings | Switching among name, country code, flag, and flag+name immediately changes the menu-bar item; a stale result is labeled after twice the selected interval. |
| Open Settings | The dashboard Settings button and app-menu Cmd-, open or restore the full Settings window. Closing Settings leaves the dashboard and its Dock icon intact, including when the dashboard is minimized. Closing the dashboard hides the Dock icon even if Settings or Event Log remain open. No settings window opens automatically. |
| External launch trace | Run `diagnose-launch.sh --trace --launch --timeout 180` before approval. Success requires a fresh matching heartbeat and `result=ready`; a pre-entry stall yields `result=blocked_before_entry` only with process-sample evidence. Confirm an early sample survives cancellation, cancellation remains a separate result, app-associated pending evaluations appear in the summary, redacted identities remain unattributed, missing permissions appear in `incomplete.txt`, and Ctrl-C or timeout leaves no collector running. Repeat opening and a Homebrew reinstall with the cached ZIP cleared; one successful launch is not a permanent-fix claim. |
| Open Dashboard | Click the persistent menu-bar flag: the dashboard opens directly with a Dock icon and Cmd-Tab entry. Verify Mission Control/App Exposé and full screen. Minimize and click the flag to restore; repeated clicks keep one window/process. Move/resize, close/reopen, and restart: the frame is preserved. Disconnect its display: the title bar stays reachable. Closing hides the Dock icon, keeps the flag, and leaves lookup and provider services running. |
| Dashboard layout and editing | Check light/dark appearances at 1000 × 860 and 520 × 380. Buttons have consistent heights and paired widths, fields stay usable, long text wraps, paths truncate with full tooltips, and the footer remains available. Enter unsaved proxy values, resize across 960 points repeatedly, and confirm values/focus survive without Save. Check missing/installed/installing/failed provider states, keyboard focus, and accessible names on removal and profile fields. |
| Manual refresh | Selecting **Refresh now** in the dashboard fetches the current public IP at once. Pressing it again within five seconds uses the next pool provider (`provider_rotated_spacing`); only with a single-provider pool does it display the queued time and run at the five-second boundary. |
| Proxy, gateway, route, or TUN/VPN change | Change a macOS proxy setting, switch Wi-Fi/Ethernet (new gateway), connect/disconnect a TUN/VPN, or toggle a TUN tool's routes. The log shows `refresh_requested` with `trigger` `network_configuration` or `route_change`, and a lookup starts at once (no debounce). Follow-up events log `refresh_event_merged`, and about five seconds later one `refresh_requested` with `trigger=trailing` runs on a different provider. A confirmed country difference creates a yellow highlight for 10 minutes. |
| Timer cadence | A 15-minute periodic timer always forces the due lookup; a one-second timing offset cannot cause an extra 15-minute skip. |
| Idle network | With no network changes for several minutes, no `route_change` or `network_configuration` refresh appears in the log (kernel noise is filtered). |
| Event burst / event window | Trigger a network-path change, wake, screen wake, session activation, and app activation within five seconds. The app performs one primary lookup immediately; routine events log `refresh_skipped` with `reason=event_window`, network events log `refresh_event_merged`, and at most one trailing lookup runs when the window ends, on a different provider. |
| Login launch | Enable **Launch at login** in the dashboard (or Settings), confirm the other window shows the same state and System Settings → Login Items lists Exit IP, sign out/in (or restart), and verify the menu-bar utility starts and performs its initial check immediately. |
| Country-change confirmation | A changed primary country is highlighted only when the independent confirmation API returns the same country; disagreement retains the last verified country and shows a confirmation message. |
| Dashboard change controls | During a highlighted change, the dashboard shows Dismiss and Turn Off Highlights with consistent sizes. Dismiss clears only the current notice; Turn Off Highlights also disables future highlights. Long country names wrap without overlapping actions. |
| Disable highlights | Turning off **Highlight country changes** clears the current alert and prevents all future change highlighting until re-enabled. |
| Same-country IP change | IP changes in dashboard/widget but does **not** create a country alert. |
| Widget | Reads the last successful snapshot without making a new request. Material data/alert changes reload it immediately; timestamp-only checks use the hourly timeline instead of consuming an on-demand reload. |
| Control Center (macOS 26+) | Resized tile exposes country code, public exit IP, last-update time, and warning symbol for a confirmed change; dashboard remains optional. Tapping the tile opens the **Exit IP Dashboard** window. |
| Quit command | Quit Exit IP in the dashboard or Cmd-Q terminates the process, removes the status item, and stops app monitoring. Closing the dashboard alone does none of these. |
| Single instance | Reopen normally, force `open -n`, and launch the bundled executable while the app is already running: only one monitor stays alive, and normal reopening shows the dashboard. Launch two executables concurrently with no app running: only one reaches `app_ready`. Quit or terminate it, then relaunch: the leftover lock file must not block startup. Copies from a development build must not run alongside the installed app. |
| Rate limit | A `429`, `401`/`402`/`403`, or quota error body pauses that provider until the persisted `Retry-After` deadline, or one hour when that header is absent. The menu bar keeps the last verified country (never `Exit IP error`) and the dashboard shows `<provider> paused until …`. The refused request is not retried elsewhere, but the next network change or **Refresh now** runs at once on another provider (`provider_rotated_cooldown`). With every provider paused, `lookup_all_providers_paused` appears and lookups resume at the earliest deadline. |
| Routine freshness | Within 2 minutes of a lookup, activate the app (open the dashboard). The log shows `refresh_skipped` with `reason=fresh` and no lookup. |
| Network change with no burst tokens | Make more than six network changes over a minute or two, each a few seconds apart (e.g. toggle a proxy or VPN repeatedly). Every change still starts a lookup at once or within its 5-second window; no `refresh_queued` with `reason=burst_budget` and `urgency=network_change` appears. `bash Scripts/check-refresh-log.sh` prints **PASS**. |
| Burst allowance (storm) | Keep a TUN tool flapping continuously for more than 30 seconds. The first ~30 seconds are checked on time. After that, `refresh_queued` with `reason=burst_budget` and `urgency=follow_up` appears and lookups settle to about one per 2 minutes, with the final state still checked. A fresh change after the storm runs at once and logs `refresh_queue_superseded` for the pending follow-up. |
| Daily budget | When a provider reaches 80% of its documented daily limit, `provider_rotated_daily_budget` shows rotation skipping it; if every provider is exhausted, `lookup_daily_budget_exhausted` pauses lookups until 00:00 UTC. |
| Provider rotation | Refresh repeatedly until each pool provider has answered. Every `lookup_succeeded` logs a two-letter country code (never `--`), the flag renders correctly for each, and same-country results never show a country-change banner. The Settings health panel updates attempt, success, failure, and daily-call data; **Test** bypasses the spacing gate and checks exactly that provider; for a paused or budget-exhausted provider it logs `provider_test_skipped` and calls nothing (no other provider is tried instead). IPinfo Lite's **Test** button is disabled until a token is loaded or saved in this app session. |
| Provider diagnostics | Use the Settings **Diagnostics** section to keep IPs redacted by default and choose 1, 7, or 30-day log retention. Run `bash Scripts/check-signed-build.sh` against the built app to inspect signing, App Group, and embedded widget-extension status. |
| Debug simulations | In a DEBUG build, run each Settings simulation for transport failure, malformed response, rate limit, country disagreement, and exit IP not on the allowlist; verify the corresponding UI/log state (for example, the allowlist simulation shows the orange **Exit IP not on the allowlist** notice while the menu bar keeps the country), then clear it. Clearing re-evaluates the real allowlist state. |
| Allowlist warning | Add an address that differs from the current exit IP. The **Exit IP Not Allowed** window opens once (`allowlist_warning_presented`), the dashboard show the orange notice, and the menu bar still shows the country (never `Exit IP error`). Refreshing with the same IP does not reopen the window. Add the current IP or empty the list; the window closes and the notice disappears (`allowlist_warning_cleared`). The connection is never blocked. |
| Tailscale → Clash Verge provider | `bash Tests/ExitIPDaemonTests/run.sh` passes, including stalled and disconnected HTTP clients closing without a response. After `sudo /bin/bash Sources/ExitIPDaemon/daemon.sh install`, `daemon.sh status` lists both jobs as loaded, `status.json` reports `direct`, `verified`, and the interface `route -n get 100.100.100.100` shows, `provider.yaml` on disk equals the served bytes, and the Mihomo member `tailscale-live/TS-NATIVE` is `Direct` on that interface with the same core PID. Disconnect and reconnect from the Tailscale menu: the member goes Direct → Reject → Direct without a profile reload, and the uncached DNS probe answers again. Stop the monitor (`sudo launchctl bootout system/com.example.exitipmonitor.tailscale-verge`): about 12 seconds later the responder serves Reject with `monitor-stale`; reinstalling restores Direct. After a restart, the log shows `no-console-user` until login, then `verified`. `daemon.sh remove` frees the port. |
| Clean uninstall and reinstall | `bash Tests/ExitIPInstallTests/run.sh` covers hung processes, TERM/KILL, unrelated processes, owner/path checks, PID reuse, translocation, respawning, inspection errors, partial provider setup, and cleanup failure before replacement. Uninstall must leave no target app process, provider jobs/workers, provider files or grant. Reinstall then creates the app and, after one password prompt, the provider, with saved settings retained. Test the old cached-cask migration separately. Dashboard provider outcomes use mocked privileged commands during app-only validation. |
| Missing Tailscale or Clash Verge Rev | `bash Tests/ExitIPDaemonTests/run.sh` covers both with stubs: the preflight's four combinations, and a missing CLI makes the monitor write `tailscale-not-installed` without running `route`, `ifconfig`, or `sudo`. `xcrun swift test` checks every reason's plain words. On a Mac without Tailscale the dashboard reads **Reject · Tailscale isn't installed** and the Event Log one `Tailscale provider · Reject (Tailscale isn't installed)` line; without Clash Verge Rev the **Clash Verge** row and **Apply in Clash Verge** say to install it. |
| Event Log | **Event Log…** in Monitoring opens **Exit IP Event Log**: one line per important event, UTC times, newest last. **Refresh now** adds `Check · Refresh now · …` then `Lookup OK · …` live; toggling Wi-Fi or a proxy adds `Check · network settings changed` or `route changed`. With Tailscale steady for minutes, no new Tailscale lines appear; a Disconnect/Connect adds exactly one `Tailscale provider · Reject (…)` and one `Tailscale provider · Direct utun7`. **Copy All** copies the lines; **Show Log Files** opens the Logs folder. |
| Error stop icon | Run the DEBUG transport-failure simulation: the menu bar and dashboard header show the stop icon instead of the flag, and the widget shows it in its error placeholder. Clearing restores the flag after the next successful lookup. |
| Dashboard provider group | With the daemon installed, the dashboard shows **Tailscale → Clash Verge provider** with the status in plain words, last check, provider file path, `http://127.0.0.1:18766/provider.yaml`, and **Clash Verge: Installed** (status only; **Open Clash Verge** is in Apply in Clash Verge). **Open File** opens the YAML in TextEdit, **Show in Finder** selects it, **Open in Browser** shows the YAML inline (not a download) and **status.json** shows the JSON. The status follows a Tailscale disconnect within a few seconds. Without the daemon, all three Clash Verge groups remain visible and the provider group shows a neutral optional state, explains that monitoring works without it and setup requires administrator authentication, and offers **Install Provider**. Cancel authentication: show cancellation and permit retry. Complete it: show progress, verify both jobs loaded, and show provider status without restarting. A setup failure retains details, the log link, and **Retry Installation**. Saved profile fields must be preserved. |
| Clash Verge profile | With or without the daemon installed, enter a proxy in **Clash Verge profile** (try an invalid port: an orange message, nothing saved), then **Save**. The file `~/Library/Application Support/ExitIPMonitor/clash-verge-profile.yaml` is mode 0600, the log shows `clash_profile_written` with no proxy details, and relaunching makes no Keychain read until the dashboard opens. Opening the dashboard fills the form by itself (one read per session, with the window responsive during a Keychain prompt); **Load proxy info** reads again. The buttons read **Load proxy info**, **Save**, and **Remove**. Following **Apply in Clash Verge** (Profiles → New → Create Profile → Local → Choose File → Save, then right-click → Select), `TS-NATIVE` is `Direct` on the routed utun and `MATCH,Proxy` traffic leaves through the proxy. **Remove** deletes the Keychain entry and the file. |
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
