# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
The release workflow publishes the section for a tag as that release's notes.

## [Unreleased]

## [1.0] - 2026-10-18

The first release: a menu-bar app showing your public exit IP address and country, with a
dashboard, settings, an exit-IP allowlist warning, a WidgetKit widget, and a macOS 26 Control
Center control. It requires macOS 14 or later (the Control Center control needs macOS 26) and
is universal: Apple silicon and Intel.

### Install

```sh
brew install --cask jxz345/tap/exit-ip-monitor
open /Applications/ExitIPMonitor.app
```

The app is ad-hoc signed (not notarized), and Homebrew keeps the download quarantine, so
approve the first launch in **System Settings → Privacy & Security → Open Anyway**. The
dashboard opens on first launch, and the country flag is in the menu bar.

If the launch hangs (the process starts but no flag appears) or **Open Anyway** is missing or
does nothing, which happens on macOS 27, first close any "ExitIPMonitor" Not Opened dialog with
**Done**. Later launches wait while that dialog or a stuck evaluation is pending. Then quit the
app, verify it, and remove quarantine for this app only:

```sh
pkill -x ExitIPMonitor
codesign --verify --deep --strict --verbose=2 /Applications/ExitIPMonitor.app
xattr -dr com.apple.quarantine /Applications/ExitIPMonitor.app
open /Applications/ExitIPMonitor.app
```

If it still hangs, restart the Mac (this ends any pending evaluation) and open the app again.
If `xattr` reports **Operation not permitted**, allow your terminal (Terminal, or Visual
Studio Code) under **Privacy & Security → App Management**, then retry.

Without Homebrew, double-click `ExitIPMonitor-1.0.pkg` (approve it once with **Open
Anyway**), or run
`curl -fsSL https://github.com/jxz345/exit-ip-widget/releases/latest/download/install.sh | bash`.

### Fixed
- Earlier builds of this release carried the build Mac's `com.apple.provenance` stamps on every
  file, so the launch stalled on other Macs even after quarantine removal. Releases are now
  built on a clean GitHub runner and carry no extended attributes.
- Copies of earlier builds were reported as "damaged": their signature didn't cover the whole
  app. The app is now fully ad-hoc signed and universal.

### Known limitations
- Not notarized: the first launch needs **Open Anyway** or the quarantine recovery above.
  Changing that needs a paid Apple Developer account.
- No App Group (also needs a developer team), so the widget and Control Center control can't
  show the app's data. Build with
  `Scripts/generate-xcode-project.sh --signed-build --team ID --app-group ID` for those.
