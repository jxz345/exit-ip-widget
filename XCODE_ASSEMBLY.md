# Assemble Exit IP Monitor in Xcode

This guide starts with the supplied `ExitIPMonitor-source-kit.zip` archive and ends with a runnable macOS menu-bar app, and WidgetKit extension (with the macOS 26 Control Center control). It assumes you have selected full Xcode with `xcode-select` and that the preflight check passes.

> **Keep the supplied source kit intact.** The folder named `exit_ip_widget` is the source-kit root. The Xcode project references source files inside it; it must not create copied duplicates of those files.

---

## 1. Extract the source kit and establish `KIT_ROOT`

Run these commands in Terminal. The archive name assumes a standard browser download; change only the `ARCHIVE` value if yours differs.

```bash
ARCHIVE="$HOME/Downloads/ExitIPMonitor-source-kit.zip"
WORKSPACE="$HOME/Developer/ExitIPMonitor"

mkdir -p "$WORKSPACE"
unzip -q "$ARCHIVE" -d "$WORKSPACE"

KIT_ROOT="$WORKSPACE/exit_ip_widget"
cd "$KIT_ROOT"
test -f Package.swift && test -d Sources && test -d Tests && test -d Configuration
printf 'Source-kit root: %s\n' "$KIT_ROOT"
```

The resulting folder tree must begin as follows:

```text
$HOME/Developer/ExitIPMonitor/
└── exit_ip_widget/                 ← KIT_ROOT
    ├── Package.swift
    ├── Sources/
    │   ├── ExitIPShared/
    │   ├── ExitIPMonitorApp/
    │   └── ExitIPMonitorWidgets/
    ├── Configuration/
    ├── Tests/
    └── Scripts/
```

All Terminal commands in steps 2–3 and 11 run from **`KIT_ROOT`**. Do not run them from Downloads, from `XcodeProject`, or from a folder containing only a copied script.

---

## Recommended: generate, copy, and compile the Xcode project automatically

The `XcodeProject` folder in a fresh kit is **supposed to be empty**. It is reserved for generated content. Do not drag source files into it or create an empty Xcode project by hand.

After completing the Xcode selection and preflight checks in the next sections, run this command from the source-kit root:

```bash
cd "$KIT_ROOT"
bash Scripts/generate-xcode-project.sh
```

The script:

1. runs `xcrun swift test` for the shared core;
2. copies the supplied `Sources/` and `Configuration/` folders into `XcodeProject/`;
3. configures and generates `XcodeProject/ExitIPMonitor.xcodeproj` with the menu-bar app, WidgetKit extension, Control Center control, source target membership, extension embedding, Info plists, and entitlements;
4. downloads the pinned XcodeGen project generator **only if** it is not already available;
5. compiles with code signing disabled by default; and
6. saves all standard output and errors to a timestamped file in `XcodeProject/Logs/`.

At the end of every run it prints one of these paths:

```text
SUCCESS
Build log: /Users/you/Developer/ExitIPMonitor/exit_ip_widget/XcodeProject/Logs/generate-and-build-YYYYMMDD-HHMMSS-PID.log
```

or:

```text
FAILED (exit N). Attach this file for diagnosis:
/Users/you/Developer/ExitIPMonitor/exit_ip_widget/XcodeProject/Logs/generate-and-build-YYYYMMDD-HHMMSS-PID.log
```

If the script fails, attach that **one log file**. It includes the test output, generator output, and `xcodebuild` diagnostics.

### Updating an already generated project

When a revised source kit fixes app behavior, do not modify files inside `XcodeProject/Sources` by hand. Update the source-kit files, then run:

```bash
cd "$KIT_ROOT"
bash Scripts/generate-xcode-project.sh --force --open
```

This replaces the generator-owned copies, project, and DerivedData while preserving the `Logs` folder. Quit a previously running Exit IP app before launching the rebuilt one.

The current kit includes menu-bar reliability changes:

- Once a lookup completes, the menu label redraws from `Locating` to the selected country name, flag, or flag-and-name presentation. It contains no extra globe icon.
- **Open Dashboard** brings a retained **Exit IP Dashboard** window to the front directly; it no longer depends on a SwiftUI `openWindow` scene action from the menu-bar popover.

The current kit also observes SystemConfiguration proxy, route, DNS, service, and interface (including `utun`) changes. The generated app target links `SystemConfiguration.framework`; do not remove that framework. A configuration change coalesces for one second before a lookup; an event arriving during an in-flight lookup requests one post-lookup recheck. Non-startup refreshes use the same persistent five-second gate, while startup performs one immediate lookup. The popover also includes **Quit Exit IP** for terminating the menu-bar utility intentionally.

If an earlier revision reports Swift 6 errors about non-Sendable `CFString` static properties, `String` not converting to `CFString`, or `return` inside a `defer` statement, update to this kit and rerun with `--force`. The observer now builds its Core Foundation key/pattern arrays locally with explicit `NSString` bridging, and the post-lookup recheck uses valid `defer` control flow.

### Signed, runnable build

The default build is intentionally unsigned so you can verify the project compiles before configuring Apple signing. To generate a signed project that can run on your Mac, first register the App Group for your Developer Team, then run:

```bash
cd "$KIT_ROOT"
bash Scripts/generate-xcode-project.sh \
  --force \
  --app-group group.com.example.exitipmonitor \
  --team YOUR_TEAM_ID \
  --signed-build \
  --open
```

Replace both placeholder values with your actual registered App Group and ten-character Team ID. `--force` replaces only generator-owned material inside `XcodeProject` while preserving the log folder. Use `--generate-only` to create the project without compiling, and `--skip-tests` only when you have already run the shared-core tests successfully.

The remaining manual target-assembly steps are retained below as reference only; **do not perform them after using the generator**, because the project already contains those targets and source memberships.

---

## Where the executable is, and local-install limits

After an unsigned generator build succeeds, it prints both paths. They are also predictable:

```text
App bundle:  $KIT_ROOT/XcodeProject/DerivedData/Build/Products/Debug/ExitIPMonitor.app
Executable:  $KIT_ROOT/XcodeProject/DerivedData/Build/Products/Debug/ExitIPMonitor.app/Contents/MacOS/ExitIPMonitor
```

Launch the app bundle—not the inner executable—using:

```bash
open "$KIT_ROOT/XcodeProject/DerivedData/Build/Products/Debug/ExitIPMonitor.app"
```

The app bundle can be copied to `~/Applications` for a personal local copy, but the default generator output is unsigned. It is appropriate for local testing, not normal installation or distribution. macOS may ask you to approve opening it.

An Apple developer team and registered App Group are required for the full feature set: the app, widget extension, and Control Center control use the shared App Group state. Without a team-backed App Group, the menu-bar app (including the allowlist warning) can run as an unsigned local test, but the widget and Control Center control cannot read its data. See Apple’s [App Group documentation](https://developer.apple.com/documentation/xcode/configuring-app-groups).

---

## 2. Select full Xcode

First identify the installed Xcode app:

```bash
ls -d /Applications/Xcode*.app
```

If the normal application is shown as `/Applications/Xcode.app`, select it:

```bash
sudo xcode-select --switch "/Applications/Xcode.app/Contents/Developer"
xcodebuild -version
```

If the preflight reports that first-launch setup or the license is outstanding, run only the command it names:

```bash
sudo xcodebuild -runFirstLaunch
sudo xcodebuild -license accept
```

---

## 3. Run the preflight and shared-core tests

From the source-kit root:

```bash
cd "$KIT_ROOT"
bash Scripts/check-build-environment.sh
bash Scripts/check-build-environment.sh --test
```

The `--test` option runs only the portable shared package: `Sources/ExitIPShared` and `Tests/ExitIPSharedTests`. It does **not** build a SwiftUI app, a WidgetKit extension, or a Control Center control.

For the full diagnostic if the test fails, use the exact command below and keep the resulting `swift-test.log`:

```bash
cd "$KIT_ROOT"
xcrun swift test --verbose 2>&1 | tee swift-test.log
```

The last two lines, `error: Build failed` and `fatalError`, are Swift Package Manager summaries. The actionable information is the **first earlier line containing `error:`** in `swift-test.log`.

### Optional: download a standalone Swift toolchain

**Do not do this to build the app.** Full Xcode is required for SwiftUI, WidgetKit, code signing, and the macOS 26 Control Center API; Xcode already includes Swift. The optional standalone toolchain below is only useful if you want to run `swift test` independently of Xcode.

The supplied script downloads the small **Swiftly installer** from Swift.org and lets it download the selected Swift toolchain to your user account at runtime. The source kit does **not** include or package a Swift toolchain.

```bash
cd "$KIT_ROOT"
bash Scripts/install-standalone-swift.sh
```

Open a **new Terminal window** after it completes, then run:

```bash
cd "$KIT_ROOT"
swift test --verbose 2>&1 | tee swift-test.log
```

The script follows the current official [Swift.org macOS installation](https://www.swift.org/install/macos/) method. It is deliberately optional: on a Mac with correctly selected Xcode, use `xcrun swift test` instead to ensure the test compiler matches the Xcode build compiler.

---

## 4. Create a home for the Xcode project

Keep the `.xcodeproj` separate from, but inside, the source kit:

```bash
cd "$KIT_ROOT"
mkdir -p XcodeProject
open XcodeProject
```

Finder opens a folder called `XcodeProject`. Leave that Finder window open; Xcode will save the project there.

---

## 5. Create the macOS app target in Xcode

1. Open **Xcode**.
2. Choose **File → New → Project…**.
3. Select **macOS** at the top.
4. Select the **App** template, then click **Next**.
5. Use these settings:

   | Field | Value |
   | --- | --- |
   | Product Name | `ExitIPMonitor` |
   | Team | Your Apple developer team, if available; otherwise choose None temporarily |
   | Organization Identifier | Your reverse-DNS identifier, for example `com.jay` |
   | Interface | **SwiftUI** |
   | Language | **Swift** |
   | Testing System | **None** (the supplied SwiftPM tests remain under `Tests/`) |
   | Storage | **None** |

6. Click **Next**.
7. In the save dialog, choose the `XcodeProject` folder created in step 4, then click **Create**.

You should now have:

```text
$KIT_ROOT/XcodeProject/ExitIPMonitor.xcodeproj
```

---

## 6. Configure the app target

In Xcode’s Project navigator, click the top-level blue **ExitIPMonitor** project icon. Select the **ExitIPMonitor** target.

### General tab

1. Set **Minimum Deployments** to **macOS 14.0** or later.
2. Under **Signing & Capabilities**, choose the same Apple developer **Team** that you will use for the widget extension.
3. Enable **Automatically manage signing**.
4. Under **Frameworks, Libraries, and Embedded Content**, click **+**, search for **SystemConfiguration.framework**, and add it to the **ExitIPMonitor app target**. This framework delivers proxy, route, DNS, service, and `utun` interface notifications.

### Build Settings tab

1. Search for **Generate Info.plist File** and set the app target value to **No**. This prevents Xcode’s generated Info.plist from conflicting with the supplied file.
2. Search for **Info.plist File**.
3. Set the app target value to:

   ```text
   $(SRCROOT)/../Configuration/ExitIPMonitor-Info.plist
   ```

4. Search for **Code Signing Entitlements**.
5. Set the app target value to:

   ```text
   $(SRCROOT)/../Configuration/ExitIPMonitor.entitlements
   ```

`SRCROOT` is the `XcodeProject` folder, so `../Configuration` correctly points to the supplied configuration directory. Leave the widget extension’s generated Info.plist setting unchanged; only the containing menu-bar app uses the supplied `ExitIPMonitor-Info.plist`.

---

## 7. Remove Xcode’s template Swift files

The new-project template adds its own `ExitIPMonitorApp.swift`, `ContentView.swift`, and possibly test files. They conflict with the supplied app entry point.

1. In the Project navigator, select each generated template Swift file.
2. Press **Delete**.
3. Choose **Move to Trash** for template files located inside `XcodeProject`.
4. Do **not** delete anything under the supplied `Sources/`, `Configuration/`, or `Tests/` folders.

At this point, the app target should contain no generated SwiftUI source files.

---

## 8. Add the supplied app and shared source files

Choose **File → Add Files to “ExitIPMonitor”…**. Navigate from `XcodeProject` up one level to `exit_ip_widget`, then into `Sources`.

For every add-files operation below:

- select **Create groups**;
- **uncheck “Copy items if needed”**;
- check only the target(s) specified below;
- click **Add**.

### Add shared sources to the app target

Add every Swift file in:

```text
Sources/ExitIPShared/
```

In the add-files dialog, check **ExitIPMonitor**. These files will also be added to the widget extension in step 10.

### Add app-only sources

Add these files from `Sources/ExitIPMonitorApp/` and check **ExitIPMonitor**:

```text
ExitIPMonitorApp.swift
PublicIPMonitor.swift
ExitIPViews.swift
NetworkConfigurationObserver.swift
ExitIPIntents.swift
```

`ExitIPIntents.swift` will later receive widget-extension target membership as well.

### Verify app target membership

Click each added file, open the **File inspector** on the right, and check **Target Membership**:

| File group | ExitIPMonitor app target |
| --- | --- |
| Every file in `Sources/ExitIPShared/` | Checked |
| `ExitIPMonitorApp.swift` | Checked |
| `PublicIPMonitor.swift` | Checked |
| `ExitIPViews.swift` | Checked |
| `ExitIPIntents.swift` | Checked |

---

## 9. Create the widget extension and Control Center control

1. Choose **File → New → Target…**.
2. Select **Widget Extension**, then click **Next**.
3. Use product name **`ExitIPMonitorWidgets`**.
4. Select the same Apple developer **Team** as the app.
5. Enable **Include Control**. Do not enable unrelated templates unless you need them.
6. Click **Finish**. If Xcode asks to activate the new scheme, choose **Activate**.

Select the **ExitIPMonitorWidgets** target and configure it:

1. In **General**, set the minimum deployment to **macOS 14.0** or later.
2. In **Signing & Capabilities**, select the same Team and enable automatic signing.
3. In **Build Settings**, search **Code Signing Entitlements** and set:

   ```text
   $(SRCROOT)/../Configuration/ExitIPMonitorWidgets.entitlements
   ```

4. Remove the widget and control template Swift files that Xcode generated. Choose **Move to Trash** only for those generated files under `XcodeProject`.

---

## 10. Add supplied widget files and finalize target membership

Again choose **File → Add Files to “ExitIPMonitor”…** and keep **Copy items if needed** unchecked.

### Add widget-only sources

Add these files from `Sources/ExitIPMonitorWidgets/` and check only **ExitIPMonitorWidgets**:

```text
ExitIPStatusWidget.swift
ExitIPControl.swift
```

### Share existing source files with the extension

In the Project navigator, select each file in `Sources/ExitIPShared/`. In the File inspector, also check **ExitIPMonitorWidgets** under Target Membership.

Then select `Sources/ExitIPMonitorApp/ExitIPIntents.swift` and also check **ExitIPMonitorWidgets**.

The final target-membership matrix must be:

| Source group | ExitIPMonitor app | ExitIPMonitorWidgets extension |
| --- | ---:| ---:|
| `Sources/ExitIPShared/*.swift` | Yes | Yes |
| `Sources/ExitIPMonitorApp/ExitIPMonitorApp.swift` | Yes | No |
| `Sources/ExitIPMonitorApp/PublicIPMonitor.swift` | Yes | No |
| `Sources/ExitIPMonitorApp/ExitIPViews.swift` | Yes | No |
| `Sources/ExitIPMonitorApp/NetworkConfigurationObserver.swift` | Yes | No |
| `Sources/ExitIPMonitorApp/ExitIPIntents.swift` | Yes | Yes |
| `Sources/ExitIPMonitorWidgets/*.swift` | No | Yes |

> `ExitIPControl.swift` is guarded with `@available(macOS 26.0, *)`. It compiles with a macOS 26-or-newer SDK while the extension’s deployment target remains macOS 14+.

---

## 11. Configure the App Group

Choose one App Group identifier registered for your team, such as:

```text
group.com.jay.exitipmonitor
```

Replace the placeholder `group.com.example.exitipmonitor` in all three supplied files:

```text
Sources/ExitIPShared/AppGroupIdentifier.swift
Configuration/ExitIPMonitor.entitlements
Configuration/ExitIPMonitorWidgets.entitlements
```

Then, for **both** the app target and the widget-extension target:

1. Open **Signing & Capabilities**.
2. Click **+ Capability**.
3. Add **App Groups**.
4. Select the same App Group identifier.

Do not build until the source replacement, entitlement files, and capability selections all use exactly the same App Group string.

---

## 12. Build, run, and add system surfaces

### Build from Xcode

1. Select the **ExitIPMonitor** scheme.
2. Select **My Mac**.
3. Choose **Product → Build**.
4. Choose **Product → Run**.

The app is configured as a menu-bar-first utility, so it should appear in the menu bar instead of the Dock.

### Build from Terminal

```bash
cd "$KIT_ROOT"
xcodebuild \
  -project XcodeProject/ExitIPMonitor.xcodeproj \
  -scheme ExitIPMonitor \
  -destination 'platform=macOS' \
  build
```

### Add the widget and Control Center control

- Add the regular widget through macOS’s widget gallery.
- On macOS 26 or later, open the Controls Gallery and add the Exit IP control.
- Open the app’s menu-bar item, then **Settings**, to set the provider, display style, change highlighting, refresh cadence, and optional Launch at Login behavior.

---

## 13. Troubleshooting checklist

| Symptom | Most likely fix |
| --- | --- |
| `swift test` cannot find `Package.swift` | Run `cd "$KIT_ROOT"` first; do not run it in Downloads or `XcodeProject`. |
| Preflight says source-kit root not found | Run the script at `$KIT_ROOT/Scripts/check-build-environment.sh`, or provide `--project "$KIT_ROOT"`. |
| `xcodebuild` says Command Line Tools are active | Run `sudo xcode-select --switch "/Applications/Xcode.app/Contents/Developer"`, then rerun preflight. |
| Duplicate `@main` or duplicate type errors | Delete Xcode’s generated template Swift files; do not compile them together with the supplied app files. |
| `No such module WidgetKit` | Verify that widget-only sources are assigned only to the Widget Extension target and that full Xcode, not only Command Line Tools, is selected. |
| App Group access fails or widget shows no data | Confirm the same exact App Group identifier appears in `AppGroupIdentifier.swift`, both entitlement files, and both targets’ App Groups capabilities. |
| `raw value for enum case must be a literal` in `AppGroupStorage.swift` | Update to the current source kit. The refresh intervals are now stored as literal second values (`300`, `900`, `1_800`, `3_600`), which Swift accepts as enum raw values. |
| `IntentParameter<ExitIPDestination> has no member 'dashboard'` in `ExitIPControl.swift` | Update to the current source kit. `OpenExitIPDashboardIntent` now defines an explicit `init(target: ExitIPDestination)` so the Control Center button selects the wrapped enum value rather than the property-wrapper storage type. |
| `error: Build failed` / `fatalError` from SwiftPM | Read the first preceding `error:` line in `swift-test.log`; the last two lines are only a summary. |

For the operational rationale, API choices, refresh behavior, and test plan, return to the [main README](README.md).
