# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
The release workflow publishes the section for a tag as that release's notes.

## [Unreleased]

## [1.0] - 2026-10-18

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
