# Exit IP Monitor for macOS

A native **SwiftUI + WidgetKit** implementation kit for showing the current public exit IP's country in the macOS menu bar, plus richer details in a desktop/Notification Center widget, popover, and dashboard.

> **Platform boundary:** macOS Control Center supports third-party Control Widgets on **macOS 26+**, but Apple renders them as system-managed buttons/toggles rather than fully custom multi-line widgets. The tile can show a compact data-dense title, and at larger sizes the system shows title/value information. The richer multi-line inspection view belongs in the medium desktop/Notification Center widget, menu-bar popover, and dashboard. On older macOS versions, the menu bar and WidgetKit widget remain the appropriate system surfaces.

## Liquid Glass conformance

The implementation follows Apple’s Liquid Glass guidance for macOS 26+ without forcing a visual effect into the content layer:

- **Standard SwiftUI first:** `MenuBarExtra`, `Form`, `GroupBox`, `Button`, `Picker`, `Toggle`, `WidgetKit`, and `ControlWidgetButton` are system components, so they adopt the current platform material, control shape, motion, contrast, and accessibility settings automatically.
- **No imitation glass:** The dashboard’s former custom-colored details card is now a standard `GroupBox`. The code deliberately avoids applying `glassEffect` to content cards, because Apple reserves Liquid Glass for the functional controls/navigation layer and recommends standard materials within content.
- **Meaningful color only:** yellow remains limited to the confirmed country-change status. System semantic colors provide the rest of the hierarchy, preserving legibility in light mode, dark mode, Increased Contrast, and Reduce Transparency.
- **Accessibility-friendly behavior:** the app uses native controls and avoids custom motion, so system Reduce Motion and transparency settings remain authoritative. Validate the finished Xcode build with those settings enabled before release.

## What is implemented

| Surface | Behavior |
| --- | --- |
| **Menu bar** | Defaults to the compact **color flag**. Settings offers **country name**, **country code**, **color flag**, or **flag + country name**. It shows no IP or provider information in the resting state. |
| **Change attention** | A country change is first confirmed by a **different documented API**. Only then does it trigger a change dot, bold label, accessible announcement, and a visible yellow **menu-bar popover, dashboard, and widget** banner for **10 minutes**. macOS renders menu-bar extra labels as monochrome template content, so the menu-bar dot and capsule appear in the system menu-bar color rather than yellow; the yellow treatment is visible in the popover, dashboard, and widget. The person can dismiss the current alert or permanently turn off future highlights in the popover, dashboard, or Settings. Changing IP while keeping the same country does not trigger the alert. |
| **Error state** | A failed lookup shows a clear error and hides country name/flag across the menu bar, dashboard, widget, and Control Center. **Clear error** removes the message but keeps location hidden until a successful lookup restores it. Provider country codes are validated or resolved from a known country name before a snapshot is stored. |
| **Desktop / Notification Center widget** | Small: flag, country code/name, age. **Medium (recommended for quick inspection):** country, IP, city/region when supplied, organization, relative update time, stale marker, and country-change banner — all without opening the app. |
| **Control Center (macOS 26+)** | A resizable `ControlWidgetButton` shows a compact title in the form **`JP · 203.0.113.8 · 1:45 PM`** (with ` · stale` appended when the data is older than twice the refresh interval) plus an alert symbol after a confirmed country change or while the location is hidden by an error. Resize the tile in Control Center for the system to expose more title/value space. Tapping opens the dashboard, but the country code, current public IP, and last-update time are visible without opening it. |
| **Dashboard / popover** | The **dashboard** shows public IP, country, city/region/timezone when the provider supplies it, ASN/organization, provider (**Source**), and a clear absolute **Last updated** timestamp plus relative age. A **Monitoring** group in the dashboard has the **Launch at login** toggle (the same one as Settings → Startup, with **Open Login Items Settings**). It also shows a read-only summary of refresh frequency, change-highlight state, and provider rotation order: the next provider is marked, and each provider shows whether it is paused, skipped for a missing token, or out of daily budget, plus today's calls against its budget. An **Edit in Settings…** button opens Settings. The dashboard scrolls, so its footer (**Settings**, **Clear indicators**, **Quit Exit IP**, status line) stays visible at any window size. The **popover** is the compact view: flag, country, public IP, city/region, organization, last-updated time, and relative age. On both, data older than twice the selected refresh interval gets a **refresh is overdue** notice (the menu bar prefixes **Stale ·**). During a confirmed change, both surfaces provide the same yellow notice with **Dismiss** and **Turn Off Highlights** actions. |
| **Settings window** | Opened from the **gear** button in the menu-bar popover or the **Settings** button in the dashboard; a retained AppKit window (like the dashboard) so it reliably comes to the front. Sections: **Menu bar** display style, **Change attention** highlights, **Startup** (Launch at login + Open Login Items Settings), **Refresh** frequency, **IP location service** (provider pool, per-provider health and a **Test** action that checks exactly that provider—skipped, not redirected, while it is paused or out of daily budget, IPinfo Lite token in Keychain; without a token IPinfo Lite is skipped and its health line says so), and **Diagnostics** (clear indicators, redacted logs with configurable retention). Debug builds also expose in-memory failure simulations for manual QA. |
| **Exit-IP allowlist warning** | The dashboard holds exact IPv4/IPv6 addresses you expect to exit from (empty list = no warnings). When a fresh, successful lookup returns an address outside the list, an **Exit IP Not Allowed** warning window opens once per address, and the popover and dashboard show an orange **Exit IP not on the allowlist** notice. The app **only warns**: it never blocks or changes networking, and the menu bar keeps showing the country. Failed lookups never warn. See [allowlist details](#exit-ip-allowlist-warning). |
| **Refresh engine** | Checks immediately on launch; offers an opt-in **Launch at login** setting (in the dashboard's Monitoring group and Settings → Startup); refreshes after any network-environment change (gateway/default route, routing table including TUN split routes, interface or address, proxy, DNS, VPN/tunnel), system wake, screen wake, session activation, and app activation; supports explicit **Refresh now** buttons; uses a true 15-minute default cadence; persists the last successful result; and balances promptness against provider quotas with **immediate-then-wait** event handling (the first network/system event is checked at once; further events in the next 5 seconds become one trailing lookup on the next provider in the pool) and a layered [lookup budget](#lookup-budget-prompt-checks-vs-api-limits): a hard five-second gap per provider, a 6-lookup burst allowance refilling one every 2 minutes that throttles only follow-ups (a storm lasting over 30 seconds, retries) and routine triggers—**a real network change is never queued behind it**—freshness skipping for routine triggers, per-provider daily budgets at 80% of documented limits, and cooldowns after rate-limit/quota/auth refusals (a paused provider is skipped by normal rotation; the refused request is never retried elsewhere, and a pause never hides the last verified location). `NWPathMonitor` updates that report an unchanged path are ignored. A newly started lookup supersedes any queued one. |
| **Privacy and resilience** | The selected provider sees the public IP address. Provider credentials are kept in the macOS Keychain; the widget receives only the non-secret snapshot through the App Group. |

## Exit-IP allowlist warning

The dashboard can hold a list of exact IPv4 or IPv6 addresses you expect your
traffic to exit from. An empty list turns warnings off.

After a fresh, successful lookup returns an address outside the list (or the
list is edited so the current address is no longer included), the app:

- opens an **Exit IP Not Allowed** warning window showing the address, once per
  address (refreshing with the same address does not reopen it); its **Open
  Dashboard** button goes straight to the list;
- shows an orange **Exit IP not on the allowlist** notice in the popover and
  dashboard for as long as the address stays outside the list.

The app **only warns**. It never blocks traffic, edits routes or firewall rules,
or installs a network extension, so it needs no special signing. The warning is
not an exit-IP error: the menu bar, widget, and Control Center keep showing the
verified country. Adding the current address, emptying the list, or a later
lookup that returns an allowed address closes the window and removes the notice.
A failed lookup never opens a warning.

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
| IPinfo Lite token saved | Settings | Requests an immediate check so the new credential is used. Removing the token requests no check; rotation skips IPinfo Lite until a token is saved again. |
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
| **Manual** | **Refresh now**, provider change, IPinfo token saved | Never refused by the burst allowance (it still uses a token). Subject only to the per-provider 5-second gap, provider cooldowns, and daily budgets. |
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

A provider is paused when it refuses the client: HTTP `429`; `401`/`402`/`403` (bad or missing credentials, payment required, or a quota block); or a JSON error body that reports a rate or quota limit (for example ipapi.co `"reason": "RateLimited"`). Saving a new IPinfo token clears that provider's pause so the new credential is tried at once. Removing the token also clears the pause but spends no lookup: while IPinfo Lite has no token, rotation skips it (like a paused provider) rather than producing a missing-token error that would hide the location. If IPinfo Lite is the only enabled provider, its lookup still runs and shows the missing-token error.

When a primary or confirmation service sends `429`, the app parses both seconds and HTTP-date `Retry-After` forms when supplied; otherwise it applies a conservative **one-hour** pause. It persists the deadline per provider in the App Group and does not call that provider again until the deadline. The refused request is not retried elsewhere; the next lookup (network event, timer, or **Refresh now**) runs on the next eligible pool provider, as normal rotation would after any lookup. A pause is **not an exit-IP error**: the menu bar, widget, and Control Center keep showing the last verified location, and the popover and dashboard show which provider is paused and until when. Only when every enabled provider is paused or out of daily budget do lookups wait, until the earliest moment one becomes usable. A rate-limited confirmation provider leaves the country change unconfirmed and schedules a later normal check; it is never replaced automatically. Changing to a different provider remains an explicit person-controlled configuration choice.

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
exit_ip_widget/
├── Sources/
│   ├── ExitIPShared/             # Codable snapshot, shared App Group storage, providers, Keychain helper
│   ├── ExitIPMonitorApp/         # Menu-bar app, monitor, dashboard/views, shared OpenIntent
│   └── ExitIPMonitorWidgets/     # WidgetKit desktop widget and macOS 26 Control Widget
├── Tests/ExitIPSharedTests/      # Portable shared-core tests
├── Configuration/                # App/extension entitlements and LSUIElement Info.plist
├── Scripts/check-build-environment.sh  # macOS/Xcode preflight and optional shared-core test
├── Scripts/install-standalone-swift.sh # Optional runtime download of a SwiftPM-only toolchain
├── Scripts/generate-xcode-project.sh   # Copies sources, creates Xcode project, builds, and logs
├── Scripts/check-refresh-log.sh        # Verifies from a runtime log that network changes refreshed promptly
├── Scripts/check-signed-build.sh       # Read-only signature, App Group, and widget-extension diagnostics
├── XCODE_ASSEMBLY.md              # Click-by-click project and target assembly guide
└── Package.swift                 # Tests shared core without Xcode UI targets
```

### Start here: keep the source kit intact

The archive expands to one folder named **`exit_ip_widget`**. That folder is the **source-kit root**. Do not copy individual Swift files, `Package.swift`, or `Scripts/check-build-environment.sh` into another folder and then run commands there.

There are two distinct locations after setup:

| Location | Purpose | Commands run here? |
| --- | --- | --- |
| **Source-kit root** (`exit_ip_widget`) | Contains `Package.swift`, `Sources/`, `Tests/`, `Configuration/`, and `Scripts/`. This is the authoritative copy of the sources. | **Yes.** Run preflight and `swift test` here. |
| **Xcode project folder** (`exit_ip_widget/XcodeProject`) | Holds the `.xcodeproj` that you create later. It references the source-kit files. | Only run the final `xcodebuild -project …` command from this guide, or use Xcode’s UI. |

For a fresh download, these commands create an unambiguous working location. They assume the downloaded archive is named `ExitIPMonitor-source-kit.zip` in Downloads; adjust only the `ARCHIVE` line if your browser gave it another name.

```bash
ARCHIVE="$HOME/Downloads/ExitIPMonitor-source-kit.zip"
WORKSPACE="$HOME/Developer/ExitIPMonitor"

mkdir -p "$WORKSPACE"
unzip -q "$ARCHIVE" -d "$WORKSPACE"

KIT_ROOT="$WORKSPACE/exit_ip_widget"
cd "$KIT_ROOT"
test -f Package.swift && test -d Sources && test -d Configuration
printf 'Using source-kit root: %s\n' "$PWD"
```

Expected final folder layout:

```text
$HOME/Developer/ExitIPMonitor/
└── exit_ip_widget/                 ← KIT_ROOT; use this folder for preflight and SwiftPM
    ├── Package.swift
    ├── Sources/
    ├── Tests/
    ├── Configuration/
    └── Scripts/
```

## Xcode setup

This repository’s rules allow edits only inside `agent_workspace/**`, so this kit is intentionally supplied as source and Xcode configuration rather than adding a project file outside that permitted scope.

> For the complete click-by-click procedure—extracting the archive, creating the project, adding every source file, removing Xcode templates, assigning target membership, configuring entitlements, and building—follow **[XCODE_ASSEMBLY.md](XCODE_ASSEMBLY.md)** in order.

### Automated project creation — recommended

`XcodeProject` is deliberately empty in the source kit. It is the destination for the generated, self-contained Xcode project; do not add files to it by hand. From the **source-kit root**, run:

```bash
cd "$KIT_ROOT"
bash Scripts/generate-xcode-project.sh
```

The generator does all of the following in one logged run:

1. Runs the shared Swift Package Manager tests.
2. Copies `Sources/` and `Configuration/` into `XcodeProject/`, preserving the original source kit unchanged.
3. Creates `XcodeProject/project.yml` and `XcodeProject/ExitIPMonitor.xcodeproj` with the app target, WidgetKit extension, embedded extension build phase, target membership, Info plists, and entitlements.
4. Downloads the pinned XcodeGen release only if `xcodegen` is not already installed.
5. Builds the generated project with signing disabled, so compilation can be checked before an Apple team and App Group are configured.
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

> **Menu bar and dashboard update:** The app keeps `PublicIPMonitor` as a SwiftUI `StateObject`, so the menu-bar label redraws as soon as a lookup completes. Select a country name, flag, or flag-and-name display; the menu label contains no extra globe icon. **Open Dashboard** now foregrounds a retained AppKit dashboard window instead of relying on SwiftUI scene routing from the menu-bar popover.

After updating an existing source kit, rebuild its generated project with:

```bash
cd "$KIT_ROOT"
bash Scripts/generate-xcode-project.sh --force --open
```

Then quit any old running copy of Exit IP, launch the newly built app, wait for its first lookup, and choose **Open Dashboard** from the menu-bar popover. A separate **Exit IP Dashboard** window should become key, open at the center of the current screen, and appear in front of other windows. While it is open the app temporarily shows a Dock icon and Cmd-Tab entry (macOS 14+ only lets a regular app take focus); closing the dashboard returns it to a menu-bar-only utility.

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

Inspect a built bundle before installing or requesting a signed build with the read-only diagnostics helper:

```bash
bash Scripts/check-signed-build.sh
```

The default generator build intentionally disables signing, so it is useful as a **local compilation and menu-bar-app test**. You can keep a local copy in `~/Applications` through Finder or by copying the complete `.app` bundle; do not copy only the inner `Contents/MacOS/ExitIPMonitor` executable because it depends on the bundle’s `Info.plist`, embedded widget extension, and resources.

The running app writes JSON-lines diagnostics to `~/Library/Application Support/ExitIPMonitor/Logs` (one `runtime-<launch time>.jsonl` file per launch). Set `EXIT_IP_LOG_DIRECTORY` before launching to write runtime logs somewhere else during development. Useful events when checking behavior against this README:

| Event | Meaning |
| --- | --- |
| `monitor_started` / `monitor_stopped` | App launch and quit. |
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
| `provider_test_skipped` | The Settings **Test** button was pressed for a provider that is paused (`reason=provider_paused`) or out of daily budget (`reason=daily_budget`), or IPinfo Lite has no token (`reason=missing_token`); nothing was called, and `resumeAt` says when it is usable. |
| `lookup_cancelled` / `lookup_discarded_after_stop` | A lookup was cancelled, or finished after the monitor stopped and its result was ignored. |
| `confirmation_started` / `confirmation_result` / `confirmation_failed` / `confirmation_deferred` | The one-time independent check after a country change. `confirmation_result.agrees` shows whether the change was accepted; `confirmation_deferred.reason` is `provider_paused` or `daily_budget`. |
| `widget_reload_requested` | Rendered widget content changed, so WidgetKit was asked to reload. |
| `network_configuration_changed` | The SystemConfiguration dynamic store reported changed `keys` (proxy, DNS, IPv4/IPv6, service, interface); a `network_configuration` refresh trigger follows. |
| `network_configuration_monitor_unavailable` | The SystemConfiguration observer could not be registered (`step`, `error`); proxy/DNS changes then rely on the other observers. |
| `route_monitor_unavailable` | The kernel routing socket could not be opened (`errno` included); SystemConfiguration and `NWPathMonitor` triggers still work. |
| `allowlist_warning_presented` / `allowlist_warning_cleared` | The verified exit IP is outside the allowlist and the warning window was shown for `ip` (once per address); or the window was closed because the address became allowed or the list was emptied. |
| `ipinfo_token_removed` | The IPinfo Lite token was removed; rotation skips IPinfo Lite until a token is saved. |
| `indicator_error_set` / `error_cleared` / `country_change_dismissed` | User-visible error and highlight state. |

| Goal | Apple Account / developer team needed? | Result |
| --- | --- | --- |
| Compile and locally inspect the unsigned app bundle | **No** | The app bundle is created at the Debug path above. macOS may require you to approve opening an unsigned local app. |
| Menu-bar app only, launched locally | **Usually no**, but it remains an unsupported unsigned test configuration | A local launch may work, but it is not a distributable or reliably sandboxed installation. |
| Widget, Control Center control, and shared snapshot data | **Yes** | The app and extension need an App Group registered under the same developer team so they can share the stored exit-IP snapshot. |
| Sign, install reliably, or distribute outside this development folder | **Yes** | Supply a real team and registered App Group using `--signed-build`. Notarization is additionally required for normal distribution outside the Mac. |

Apple documents that an App Group lets an app and its extension share a container and that Xcode retrieves groups from the developer account. Therefore, this project’s full menu-bar + widget + Control Center design cannot be correctly installed without an Apple developer team and a registered App Group. See Apple’s [Configuring app groups](https://developer.apple.com/documentation/xcode/configuring-app-groups).

### Prerequisites

- A **Mac** running a macOS version supported by the selected Xcode. For example, Apple lists **macOS Sequoia 15.6+** for Xcode 26; consult Apple’s current system-requirements table when selecting a newer Xcode release.
- **Full Xcode** with a **macOS 26-or-newer SDK** to compile the Control Center control. The standalone Command Line Tools package does not include `xcodebuild`, so it is not sufficient for this app and its WidgetKit extension.
- macOS 14+ deployment target for the menu-bar app and normal WidgetKit widget.
- macOS 26+ at runtime for the Control Center control.
- An Apple developer team with an App Group enabled for both targets.

> Xcode already includes the appropriate Swift compiler. Do **not** download another toolchain to build this app. A separate internet-download script exists only for optional Swift Package Manager testing: `bash Scripts/install-standalone-swift.sh`. The standalone compiler cannot build the SwiftUI app, WidgetKit extension, or Control Center control.

### Build-environment preflight and recovery

Run this **on the Mac that will build the project**, from the source-kit root established above. It is inspection-only: it makes no installations and changes no signing settings.

```bash
cd "$KIT_ROOT"
bash Scripts/check-build-environment.sh
# After the environment passes:
bash Scripts/check-build-environment.sh --test
```

If the script was copied out of the source kit—for example, into `~/Downloads`—point it back to the extracted kit explicitly:

```bash
bash ~/Downloads/check-build-environment.sh --project /path/to/exit_ip_widget
```

The script checks macOS version, the active developer directory, full Xcode and first-launch status, Xcode license, macOS SDK version, Swift, project/entitlement plist syntax, placeholder App Group identifiers, local signing identities, and (with `--test`) the portable shared-core tests. It exits nonzero when a blocking build prerequisite is missing. If Command Line Tools are active while a full Xcode app is detected, it reports **one actionable developer-directory failure** and intentionally skips dependent `xcodebuild`, license, and SDK checks until Xcode is selected. With `--test`, it now prints the exact `xcrun swift test --package-path … --verbose` command and saves the full compiler output as `swift-test.log` in the source-kit root; the first earlier `error:` line is the actionable diagnosis, not SwiftPM’s final summary.

| Preflight finding | Install or recovery method |
| --- | --- |
| **Not macOS** | Build the SwiftUI app and WidgetKit extension on a Mac. Linux—including this source-kit preparation environment—cannot build the Xcode targets. |
| **Host macOS is too old for Xcode 26** | Update macOS through **System Settings → General → Software Update**. Xcode 26 needs macOS Sequoia 15.6 or later; verify the latest compatible pairing in Apple’s [Xcode system-requirements table](https://developer.apple.com/xcode/system-requirements/). |
| **Full Xcode or `xcodebuild` missing** | Install the current compatible Xcode from the [Mac App Store](https://apps.apple.com/us/app/xcode/id497799835?mt=12) or Apple’s [Downloads](https://developer.apple.com/download/). Command Line Tools alone are not enough for `xcodebuild` or WidgetKit project builds. |
| **Source-kit root not found** | Do not run an isolated copied script as though its parent folder were the kit. `cd` into the extracted `exit_ip_widget` directory, or supply `--project /path/to/exit_ip_widget`. |
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
2. Open **Settings** with the gear button in the popover (or **Settings** in the dashboard).
3. Choose the menu-bar **Display** mode: `Color flag` (default), `Country name`, `Country code`, or `Flag and country name`. The menu label contains only that country presentation (plus the country-change indicator when applicable), with no extra globe icon.
4. Use **Highlight country changes** to enable/disable all future country-change highlights. A visible alert can also be dismissed individually from the menu-bar popover or dashboard. With it enabled, a country change must agree with a second documented API before it is highlighted.
5. Enable **Launch at login** in the dashboard's **Monitoring** group, or in the **Startup** section of Settings, if the utility should start and check during a fresh user login. macOS can require approval; use **Open Login Items Settings** if requested. The login item points to the app bundle at its current path, so copy `ExitIPMonitor.app` to `/Applications` and launch it from there before enabling it. A build run from `XcodeProject/DerivedData` is replaced on every `--force` regenerate.
6. Use **Refresh now** in the menu-bar popover or dashboard whenever an immediate lookup is needed. It runs at once on the next pool provider not called in the last five seconds; only when every enabled provider was called within five seconds does it queue for the earliest boundary.
7. Leave the default provider pool (`ipapi.co`, IPWHOIS.io, `ipapi.is`) for a no-token trial, or add/select **IPinfo Lite** and save a free token (the token field appears whenever IPinfo Lite is in the pool). The token stays in Keychain. The active provider is persisted and advances after every successful lookup, so a relaunch continues from wherever the rotation left off rather than always starting with `ipapi.co`.
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

## Test plan

| Check | Expected result |
| --- | --- |
| First launch | Menu label changes from `Locating` to the selected country display after an immediate check. Dashboard shows public IP, provider data, absolute **Last updated** time, and relative age. |
| Menu settings | Switching among name, country code, flag, and flag+name immediately changes the menu-bar item; a stale result is labeled after twice the selected interval. |
| Open Settings | The gear button in the popover and the **Settings** button in the dashboard both open or bring forward the **Exit IP Settings** window. The Dock icon disappears only after both the dashboard and settings windows are closed. Launching the app opens no settings window on its own. |
| Open Dashboard | Selecting **Open Dashboard** from the menu-bar popover opens or brings forward the separate **Exit IP Dashboard** window. Close it, then select the command again; it should reappear. |
| Manual refresh | Selecting **Refresh now** in the dashboard or menu-bar popover fetches the current public IP at once. Pressing it again within five seconds uses the next pool provider (`provider_rotated_spacing`); only with a single-provider pool does it display the queued time and run at the five-second boundary. |
| Proxy, gateway, route, or TUN/VPN change | Change a macOS proxy setting, switch Wi-Fi/Ethernet (new gateway), connect/disconnect a TUN/VPN, or toggle a TUN tool's routes. The log shows `refresh_requested` with `trigger` `network_configuration` or `route_change`, and a lookup starts at once (no debounce). Follow-up events log `refresh_event_merged`, and about five seconds later one `refresh_requested` with `trigger=trailing` runs on a different provider. A confirmed country difference creates a yellow highlight for 10 minutes. |
| Timer cadence | A 15-minute periodic timer always forces the due lookup; a one-second timing offset cannot cause an extra 15-minute skip. |
| Idle network | With no network changes for several minutes, no `route_change` or `network_configuration` refresh appears in the log (kernel noise is filtered). |
| Event burst / event window | Trigger a network-path change, wake, screen wake, session activation, and app activation within five seconds. The app performs one primary lookup immediately; routine events log `refresh_skipped` with `reason=event_window`, network events log `refresh_event_merged`, and at most one trailing lookup runs when the window ends, on a different provider. |
| Login launch | Enable **Launch at login** in the dashboard (or Settings), confirm the other window shows the same state and System Settings → Login Items lists Exit IP, sign out/in (or restart), and verify the menu-bar utility starts and performs its initial check immediately. |
| Country-change confirmation | A changed primary country is highlighted only when the independent confirmation API returns the same country; disagreement retains the last verified country and shows a confirmation message. |
| Popover change controls | During a highlighted change, the menu-bar popover shows the same country-change notice as the dashboard. **Dismiss** clears just the current notice; **Turn Off Highlights** also disables future highlights. |
| Disable highlights | Turning off **Highlight country changes** clears the current alert and prevents all future change highlighting until re-enabled. |
| Same-country IP change | IP changes in dashboard/widget but does **not** create a country alert. |
| Widget | Reads the last successful snapshot without making a new request. Material data/alert changes reload it immediately; timestamp-only checks use the hourly timeline instead of consuming an on-demand reload. |
| Control Center (macOS 26+) | Resized tile exposes country code, public exit IP, last-update time, and warning symbol for a confirmed change; dashboard remains optional. Tapping the tile opens the **Exit IP Dashboard** window. |
| Quit command | The menu-bar popover provides **Quit Exit IP**. Selecting it terminates the process and stops timers, path monitoring, workspace observers, and SystemConfiguration observation. |
| Rate limit | A `429`, `401`/`402`/`403`, or quota error body pauses that provider until the persisted `Retry-After` deadline, or one hour when that header is absent. The menu bar keeps the last verified country (never `Exit IP error`) and the popover shows `<provider> paused until …`. The refused request is not retried elsewhere, but the next network change or **Refresh now** runs at once on another provider (`provider_rotated_cooldown`). With every provider paused, `lookup_all_providers_paused` appears and lookups resume at the earliest deadline. |
| Routine freshness | Within 2 minutes of a lookup, activate the app (open the dashboard). The log shows `refresh_skipped` with `reason=fresh` and no lookup. |
| Network change with no burst tokens | Make more than six network changes over a minute or two, each a few seconds apart (e.g. toggle a proxy or VPN repeatedly). Every change still starts a lookup at once or within its 5-second window; no `refresh_queued` with `reason=burst_budget` and `urgency=network_change` appears. `bash Scripts/check-refresh-log.sh` prints **PASS**. |
| Burst allowance (storm) | Keep a TUN tool flapping continuously for more than 30 seconds. The first ~30 seconds are checked on time. After that, `refresh_queued` with `reason=burst_budget` and `urgency=follow_up` appears and lookups settle to about one per 2 minutes, with the final state still checked. A fresh change after the storm runs at once and logs `refresh_queue_superseded` for the pending follow-up. |
| Daily budget | When a provider reaches 80% of its documented daily limit, `provider_rotated_daily_budget` shows rotation skipping it; if every provider is exhausted, `lookup_daily_budget_exhausted` pauses lookups until 00:00 UTC. |
| Provider rotation | Refresh repeatedly until each pool provider has answered. Every `lookup_succeeded` logs a two-letter country code (never `--`), the flag renders correctly for each, and same-country results never show a country-change banner. The Settings health panel updates attempt, success, failure, and daily-call data; **Test** bypasses the spacing gate and checks exactly that provider; for a paused or budget-exhausted provider it logs `provider_test_skipped` and calls nothing (no other provider is tried instead). IPinfo Lite's **Test** button is disabled while no token is saved. |
| Provider diagnostics | Use the Settings **Diagnostics** section to keep IPs redacted by default and choose 1, 7, or 30-day log retention. Run `bash Scripts/check-signed-build.sh` against the built app to inspect signing, App Group, and embedded widget-extension status. |
| Debug simulations | In a DEBUG build, run each Settings simulation for transport failure, malformed response, rate limit, country disagreement, and exit IP not on the allowlist; verify the corresponding UI/log state (for example, the allowlist simulation shows the orange **Exit IP not on the allowlist** notice while the menu bar keeps the country), then clear it. Clearing re-evaluates the real allowlist state. |
| Allowlist warning | Add an address that differs from the current exit IP. The **Exit IP Not Allowed** window opens once (`allowlist_warning_presented`), the popover and dashboard show the orange notice, and the menu bar still shows the country (never `Exit IP error`). Refreshing with the same IP does not reopen the window. Add the current IP or empty the list; the window closes and the notice disappears (`allowlist_warning_cleared`). The connection is never blocked. |
| Liquid Glass accessibility | On macOS 26+, check light/dark appearance plus Reduce Transparency, Increase Contrast, and Reduce Motion. Standard controls and `GroupBox` retain a coherent system appearance without custom glass overlays. |
| Build preflight | `bash Scripts/check-build-environment.sh` reports no failures; `bash Scripts/check-build-environment.sh --test` completes the shared-core tests on the build Mac. |

Run portable shared-core tests from the **source-kit root**, not from Downloads, not from `XcodeProject`, and not from a folder containing only a copied script:

```bash
cd "$KIT_ROOT"
xcrun swift test --verbose 2>&1 | tee swift-test.log
```

The test package deliberately builds only `Sources/ExitIPShared` and `Tests/ExitIPSharedTests`; it does **not** build the SwiftUI app or WidgetKit extension. `RefreshScenarioTests` runs the real shared refresh policy (`EventRefreshWindow`, `RefreshGate`, `LookupBudget`, `PendingRefresh`) on a virtual clock the way `PublicIPMonitor` wires it. The scenarios include a replay of real logged network events, an empty burst bucket, a VPN connect, settings changed seconds apart, an hour-long event storm, all-day flapping against the daily budgets, and queue superseding.

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
