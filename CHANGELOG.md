# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
Use the section for a version as that release's notes.

## [2.0] - 2026-10-20

Version **2.0 (build 11)**, built and tested on this Mac without GitHub Actions; v1.0 stays
published as the rollback. Upgrade from 1.0 with
`brew upgrade --cask jxz345/tap/exit-ip-monitor`. It asks for your password once, for the
provider. Build 10 replaced the first 2.0 upload (build 9) in place, and build 11 replaced
build 10. A Mac that already has build 9 or 10 needs
`rm -f "$(brew --cache --cask jxz345/tap/exit-ip-monitor)" && brew update &&
brew reinstall --cask jxz345/tap/exit-ip-monitor`, because a same-version rebuild isn't an
upgrade.

### Install

- `brew install`, `upgrade` and `reinstall` again set up the Tailscale → Clash Verge provider:
  the cask's postflight runs the bundled `daemon.sh install` with `sudo` after the app is in
  place, with one password prompt, as builds 2–6 and Sleepless did. The provider is a
  LaunchDaemon, so it survives restarts.
- The step is skipped while the opt-out marker from `daemon.sh remove` exists. A cancelled
  password or a failed setup never fails the app install; the dashboard then offers
  **Install Provider**.
- `brew uninstall` removes both services, workers, files and the grant through the removal
  grant, without a password.
- Unchanged: the preflight that verifies the signature and removes the download quarantine (so
  there is no **Open Anyway**), and the uninstall cleanup.

### App

- **Dock icon = menu-bar icon.** While the dashboard is open, the Dock and Cmd-Tab icon is the
  menu-bar label itself: the same flag or text style, stale prefix, stop symbol after a failed
  lookup, and country-change highlight. It updates at the same moment as the menu bar, colored
  for the system appearance.
- **⌘Q closes the windows** (dashboard, Settings, Event Log) instead of quitting, so monitoring
  continues. Quit with **Quit Exit IP** or the app menu's Quit. Homebrew and logout quits are
  unchanged. In 1.0, ⌘Q from the dashboard quit the whole app.
- **Launch at login is remembered.** The choice is stored, and every launch restores a
  registration that macOS dropped (for example after a reinstall). The Event Log shows
  restorations and failures.
- **Proxy info.** The dashboard reads the saved proxy from the Keychain once per app session, in
  the background, so the Clash Verge profile form is filled when it opens. The buttons are now
  **Load proxy info**, **Save** and **Remove**, with captions that say they act on the one
  Keychain entry, and that Save writes and Remove deletes the generated profile file. The IPinfo
  token is still read only by its explicit Load or Save.
- **Load proxy info**, **Save** and **Remove** share one row at every window size. The
  dashboard has one **Open Clash Verge** button, in Apply in Clash Verge; the provider's
  Clash Verge row shows only whether it is installed.
- `diagnose-launch.sh` adds the lock/unlock hint to a blocked-before-entry error.
- Build 10: The provider section no longer shows **Installation details** or **Show Installation Log**.
  The setup output is still saved to `~/Library/Application Support/ExitIPMonitor/Logs/daemon-setup-*.log`.
- Build 11: while the exit IP isn't on the allowlist, the menu bar shows a red stop icon next to
  the flag or country name, and the Dock and Cmd-Tab icon shows only the red stop icon.

### Docs

- README gains **Maintainer notes (for the next coding session)**: the cask design, the macOS 27
  parked-approval signature and recovery, fresh-identity trials, the install matrix, and the app
  techniques above.

## [1.0] - 2026-10-19

Replacement release **1.0 (8)**. Built and tested locally, published manually without GitHub
Actions. The existing `v1.0` URLs and cask version `1.0` are retained. The release contains a
universal ad-hoc signed app for macOS 14 or later, with menu-bar monitoring, dashboard,
allowlist warnings, Event Log, WidgetKit widget, and a macOS 26 Control Center control.
The optional Tailscale → Clash Verge integration requires explicit setup.

### Homebrew first launch — cask update, no app rebuild

- The launch stall's root cause is macOS, not the app. On macOS 27, choosing **Use Password** in
  the **Open Anyway** authentication can cancel the approval when loginwindow has a background
  Touch ID request running. macOS parks the approval until the next screen unlock, logout or
  restart, or another Touch ID use. Until then every launch of the app from that path waits
  before startup, quarantined or not. A restart seemed to fix it because it releases the
  parked approval.
- Before moving the app into place, the cask now verifies the staged app's signature and removes
  its download quarantine (`preflight_steps`, no `sudo`). A Homebrew install opens with no
  **Not Opened** dialog, no **Open Anyway** and no password. A failed signature check aborts
  the install.
- For a parked approval (the package, a copied app, or a leftover from an earlier attempt), lock
  the screen (Control-Command-Q) and unlock it; the waiting app then starts. Approve **Open
  Anyway** with Touch ID rather than **Use Password**.
- Tested on the affected Mac, each trial starting from a fresh Gatekeeper prompt. **Use Password** parked the
  approval; removing quarantine did not release it, but lock/unlock did. **Touch ID** approved
  at once. The cask's preflight steps opened the app without a prompt on install and reinstall.
- The release ZIP, its checksum and build 1.0 (8) were unchanged by this cask update.

### Install or replace an earlier 1.0 build

```sh
brew install --cask jxz345/tap/exit-ip-monitor
```

Existing Homebrew users must follow the README clean-uninstall migration for old cached
hooks, clear the cached ZIP, and reinstall. `brew upgrade` cannot detect this same-version
replacement. Startup accesses no Keychain.
The app is not notarized. After verifying the signature, the cask removes the app's download
quarantine, so Homebrew installs need no **Open Anyway** (see above).
A real Homebrew install and reinstall passed, including termination of an actual hung app
after normal Quit failed. The app and user-file checks passed and no provider was installed.
The earlier stall before application entry after approval was macOS parking its own Gatekeeper
override authentication, not an app startup operation. The cask update above avoids it.

### Explicit Keychain access — build 1.0 (8)

- Access Keychain only through **Load saved profile**, **Load saved token**, Save, or Remove.
  Launching, opening windows, status checks, and automatic refresh make no credential reads.
- Run credential operations on a serial background queue, keep the UI responsive while
  macOS authentication is pending, and prevent duplicate or overlapping edits.
- Cache explicitly loaded/saved credentials for the current app session. Anonymous providers
  continue while IPinfo waits for its token; an IPinfo-only pool retains the last result and
  spends no lookup until a token is loaded or saved.
- Update the generated proxy profile only after explicit Load or Save. Failed reads preserve
  existing files and cached values. Record credential operation/outcome/duration without secrets.
- Skip the planned build 7 reboot comparison and test build 8 through the actual published
  Homebrew tap. The Keychain change addresses the separate wait after application entry.

### App-only installation and verified cleanup — included from build 1.0 (7)

- Preserve early process evidence when launch tracing is cancelled, and distinguish a
  pending macOS evaluation from startup observations and the diagnostic command's result.
- Remove automatic provider installation from the companion Homebrew cask. Install the
  optional provider only through the dashboard or an explicit administrator command.
- Clean uninstall/reinstall verifies that app processes have exited, with targeted TERM/KILL
  fallback for pre-startup hangs, and verifies removal of both provider services and files.
  Cleanup failure prevents replacement; settings, credentials and logs are retained.
- Package and shell replacement use the new cleanup helper. The cask embeds it, with a
  one-time migration procedure for older cached uninstall hooks.
- Show the absent provider as optional setup, with a visible authentication explanation.
- Disable the GitHub Release workflow and remove its configuration. Replace all four v1.0
  assets consistently and update the tap checksum only after verifying the downloads.
- These release notes supersede the historical build 6 installation behavior below.

## [1.0 build 6] - 2026-10-18 (historical)

The first release: a menu-bar app showing your public exit IP address and country, with a
dashboard, settings, an exit-IP allowlist warning, an event log, a WidgetKit widget, and a macOS 26
Control Center control. It also runs the Tailscale → Clash Verge provider and maintains the Clash
Verge profile that uses it. It requires macOS 14 or later (the Control Center control needs
macOS 26) and is universal: Apple silicon and Intel. This build is 1.0 (6); it replaces the previous 1.0 assets.

### Install

```sh
brew install --cask jxz345/tap/exit-ip-monitor
open /Applications/ExitIPMonitor.app
```

Homebrew asks for your password once, to install the Tailscale → Clash Verge provider daemon,
and prints whether Tailscale and Clash Verge Rev are installed. Without them the daemon still
runs and serves Reject, and the dashboard says what's missing. `brew uninstall` removes the daemon
without a password. If you installed the first 1.0 build, run
`rm -f "$(brew --cache --cask jxz345/tap/exit-ip-monitor)" && brew reinstall --cask jxz345/tap/exit-ip-monitor`:
the version number didn't change, so `brew upgrade` doesn't see this build.

The app is ad-hoc signed (not notarized), and Homebrew keeps the download quarantine, so
approve the first launch in **System Settings → Privacy & Security → Open Anyway**. The
dashboard opens on first launch, and the country flag is in the menu bar.

Build 3 passed normal approval with quarantine retained, but build 5 reproduced the pre-startup
stall after a Homebrew reinstall. Build 6 captures the pending approval/authentication sequence
externally; it does not claim to fix the stall. Start capture before approval with:

```sh
/bin/bash /Applications/ExitIPMonitor.app/Contents/Resources/diagnose-launch.sh --trace --launch --timeout 180
```

Without Homebrew, double-click `ExitIPMonitor-1.0.pkg` (approve it once with **Open
Anyway**), or run
`curl -fsSL https://github.com/jxz345/exit-ip-widget/releases/latest/download/install.sh | bash`.

### Dashboard window and controls

- The persistent menu-bar flag opens the regular dashboard window directly, replacing the
  compact popup. The window participates in Mission Control, App Exposé, window cycling,
  and full screen; it remembers its frame and restores from minimization.
- The Dock icon appears while the dashboard is open or minimized and disappears when it
  closes, even with Settings/Event Log open. Monitoring and the status item continue.
- Native dashboard buttons share regular sizing and aligned action groups; profile fields
  have full-width rows. File actions, long notices, and provider status have room to wrap.
- Resizing between one and two columns preserves unsaved profile edits. Standard app menus
  support Settings, Close, Minimize, editing commands, and Quit.
- Release checks now time stalled HTTP clients directly. The provider also closes incomplete
  requests without a response on macOS Bash 3.2, whose timeout exit code differs from newer Bash.

### Dashboard provider installation

- Missing or incomplete daemon setup now stays visible with **Install Provider**; profile
  editing and import instructions remain available instead of disappearing.
- The button uses native macOS administrator authentication, as Sleepless does, and runs
  setup off the main thread. Success requires both background services loaded.
- Progress, cancellation, failures, retry, installer output, and a local diagnostic log are
  shown in the dashboard; installation lifecycle events also appear in the Event Log.
- README records the verified launch solution and explains why the old dashboard hid the
  Clash Verge controls after an incomplete daemon reinstall.

### Single instance

- A process-lifetime lock prevents duplicate app processes, including concurrent executable
  launches and development copies. Duplicate attempts reopen the existing app and exit
  before monitoring starts; a crash automatically releases the lock.
- Launch Services also prohibits multiple instances. Runtime log filenames include the PID
  so simultaneous launch attempts cannot overwrite each other's diagnostics.

### Installation diagnostics

- Build 6 adds `--trace`: bounded information-level Gatekeeper/authentication capture before
  launch, even if the app never reaches its entry point. Reports retain default system
  privacy redaction and stay local; no Keychain or proxy configuration is collected.
- Summaries include version/build, verification status, startup records, observed authentication
  messages and missing-evidence notices. A missing heartbeat cannot report success.
- Collectors stop on success, timeout, launch failure and cancellation. Explicit output
  directories must be new or empty to prevent old evidence contaminating a new result.
- README records the recurring build 5 failure and distinguishes observed authentication
  errors from an established root cause. Reopening and reinstalling are separate manual checks.

- Installers require a fresh main-thread readiness response from the installed build; a PID
  blocked before startup no longer reports success.
- Added startup milestones, local launch diagnostics, step durations and exit statuses,
  and time limits for launch, daemon setup, and diagnostic commands.
- Normal Gatekeeper approval is retained. Provenance metadata alone is no longer described
  as proof of a foreign or damaged release.

### Added

- **Tailscale → Clash Verge provider**, a root daemon in bash (`Sources/ExitIPDaemon`). It keeps
  Mihomo's `TS-NATIVE` provider member bound to the current, verified native Tailscale `utun` and
  serves it at `http://127.0.0.1:18766/provider.yaml`, so a Tailscale reconnect needs no profile
  reload. A root monitor checks every 2 seconds, running only the Tailscale CLI as the console
  user. A launchd-held loopback socket serves the file as `nobody`, and it serves Reject when
  Tailscale can't be verified or the monitor's last check is more than 12 seconds old. Homebrew
  installs and starts it with the app (one password prompt). Install stops whatever holds port
  18766. A launchd job, such as the earlier standalone per-user helper, is disabled and booted out
  so it stays off, and the command to allow it again is printed. The responses are byte-identical
  to that helper's.
- Macs without **Tailscale** or **Clash Verge Rev** still get the daemon, with plain-language
  messages instead of errors: the install reports which app is missing, the provider serves Reject
  with the reason "Tailscale isn't installed", and the dashboard says that nothing uses the provider
  until Clash Verge Rev is installed. Every Reject reason has plain words in the dashboard and the
  Event Log; `status.json` keeps the reason code.
- A **removal grant**, `/etc/sudoers.d/exitipmonitor-tailscale-verge`, lets `brew uninstall` remove
  the daemon without a password, like Sleepless. It allows only unloading the two jobs, restarting
  the monitor, and deleting the daemon's files and the grant itself; nothing can be loaded or
  started through it. `daemon.sh remove` turns the daemon off and keeps it off across Homebrew
  reinstalls; `daemon.sh install` turns it back on.
- The dashboard shows a **Tailscale → Clash Verge provider** group while the daemon is installed:
  what Clash is served, whether Clash Verge Rev is installed, the last check, the provider file's location (**Open File**, **Show in
  Finder**), and the address it is served at (**Open in Browser**, **status.json**). `provider.yaml`
  is served as `text/plain`, so it opens in a browser instead of downloading.
- **Clash Verge profile** in the dashboard: enter your proxy (name,
  SOCKS5 or HTTP, server, port, username, password). It is stored in the Keychain, and the app
  writes a complete Clash Verge profile to
  `~/Library/Application Support/ExitIPMonitor/clash-verge-profile.yaml` (mode 0600). The profile
  holds the settings, TUN, DNS, and rules of the verified setup, your proxy, the `tailscale-live`
  provider, and the `Proxy` and `TS-DIRECT` groups. Import it in Clash Verge once as the Local
  profile; Tailscale changes keep arriving through the provider every 3 seconds. The dashboard
  shows the file's location, and its **Apply in Clash Verge** group lists the import steps with
  Clash Verge's own labels, plus an **Open Clash Verge** button. The provider file's row explains
  that it is never imported. No installer writes it, nothing is written into Clash Verge, and the
  proxy is never logged.
- **Event Log** window (Monitoring → **Event Log…**): important events, one concise line each, with
  UTC times, loaded from the runtime logs and updated live. Tailscale provider lines appear only
  when what Clash is served changes.

### Changed

- One description of when the app checks: "Checks every 15 minutes, and right after a network, route,
  proxy, DNS, VPN/TUN, wake, or app-activation change." The dashboard's Monitoring **Schedule**
  row, the dashboard footer, Settings → Refresh all show it.
- A failed exit-IP lookup shows a **stop icon** in place of the flag on the menu bar,
  dashboard, widget, and Control Center.
- Tidier dashboard: one label column per side, single-line paths with aligned actions beneath, one caption per group, shorter labels, and numbered steps with a hanging indent.
- The dashboard opens at about 1000 × 860 in two columns, with scrolling when needed: the current exit IP and allowlist on the left, Monitoring and the Tailscale provider
  on the right. A narrow window stacks them. **Last updated** and **Age** share one row, and
  **Launch at login** sits on one row with a **Login Items…** button.

### Fixed

- Build 2 stalled before app startup on the affected Mac. A fresh verified release and normal
  macOS approval resolved the observed failure with quarantine retained; the precise macOS
  authentication failure remains unproven. Provenance metadata alone does not diagnose it.
- Copies of earlier builds were reported as "damaged": their signature didn't cover the whole
  app. The app is now fully ad-hoc signed and universal.
- The Settings window opened as a bare title bar. It now opens at full size (about 560 × 700),
  shrunk to fit smaller screens.

### Known limitations
- Not notarized: the first launch needs **Open Anyway** or the quarantine recovery above.
  Changing that needs a paid Apple Developer account.
- No App Group (also needs a developer team), so the widget and Control Center control can't
  show the app's data. Build with
  `Scripts/generate-xcode-project.sh --signed-build --team ID --app-group ID` for those.
