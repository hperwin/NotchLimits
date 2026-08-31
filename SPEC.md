# NotchLimits — Master Spec (v1)

> **Historical artifact.** This is the launch spec that drove the original parallel
> agent-fleet build. The code has since evolved (v1.2 through v1.5); where this file
> and the code disagree, the code wins. Kept for the build methodology. See README.md.

A macOS 26 notch companion. Hover under the MacBook notch: the notch appears to
slowly stretch downward (long-press anticipation), then quickly springs open into
a liquid-glass panel showing live Claude rate-limit usage for every account
managed by `cswap` (claude-swap). Leave, and it melts back into the notch.

**This is NOT NotchPet and shares nothing with it.** No AppKit frame animation,
no tabs, no retro styling. One transparent host window; SwiftUI morphs the
content. The visual model is iOS Dynamic Island / iOS 26 liquid-glass long-press.

## Hard facts about this machine

- macOS 26.4 (Darwin 25) — SwiftUI `glassEffect` IS available. Wrap in
  `if #available(macOS 26.0, *)` with `.ultraThinMaterial` fallback so the
  package also compiles if the SDK maps differently; try
  `platforms: [.macOS("26.0")]` in Package.swift first, fall back to `.v15`
  + availability guards if the tools version rejects it.
- Swift toolchain: build with
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build`.
- cswap binary: `~/.local/bin/cswap`. Data command:
  `cswap list --json` (schema below, already verified live).
- cswap daemon log (switch/poll events, one JSON per line):
  `~/Library/Logs/cswap-auto.log` — watch it to refresh instantly on switches.
- **Zero-permission rule:** no CGEvent taps, no Accessibility, no Screen
  Recording. Mouse position via polled `NSEvent.mouseLocation` only
  (global bottom-left-origin coords, same space as NSScreen frames).

## cswap JSON schema (verified live 2026-08-01)

Top level: `{schemaVersion: 1, activeAccountNumber: Int?, accounts: [...]}`.
Per account (fields may be absent — every leaf Optional in Decodable):

```json
{
  "number": 2, "email": "user@example.com",
  "organizationName": "Example Org", "alias": null,
  "active": false,
  "usageStatus": "ok" | "relogin_required",
  "usage": {                       // null when status != ok
    "fiveHour": {"pct": 0.0, "resetsAt": "2026-08-01T20:10:00.4+00:00",
                  "countdown": "3h 30m", "clock": "16:10"},
    "sevenDay": {"pct": 55.0, "resetsAt": "...", "countdown": "...", "clock": "..."},
    "scoped": [{"name": "Fable", "pct": 100.0, "resetsAt": "...", "countdown": "..."}]
  },
  "lastGoodUsage": { same shape },  // fallback when usage is null
  "usageFetchedAt": "2026-08-01T16:39:51Z", "usageAgeSeconds": 0.0,
  "lastGoodFetchedAt": "...", "lastGoodAgeSeconds": 166265.4
}
```

`resetsAt` timestamps: ISO8601 WITH fractional seconds and offset — parse with
`ISO8601DateFormatter` configured `[.withInternetDateTime, .withFractionalSeconds]`,
retry without fractional on failure. `fiveHour` may contain ONLY `pct` (no reset)
when the window is idle at 0%.

## Package layout & file ownership (streams must not cross)

```
Package.swift                      — Stream A
Sources/NotchLimits/
  main.swift                       — Stream A
  AppDelegate.swift                — Stream A
  NotchGeometry.swift              — Stream A
  HoverEngine.swift                — Stream A
  HostWindow.swift                 — Stream A
  Models.swift                     — Stream B
  UsageStore.swift                 — Stream B
  Snapshot.swift                   — Stream B
  UI/Ink.swift                     — Stream C
  UI/MorphShell.swift              — Stream C
  UI/PanelContent.swift            — Stream C
  UI/AccountRow.swift              — Stream C
  UI/MeterBar.swift                — Stream C
Resources/Info.plist               — Stream B
Scripts/bundle.sh                  — Stream B
Scripts/install.sh                 — Stream B
```

Executable name: `NotchLimits`. Bundle id `com.hayden.notchlimits`.
`LSUIElement = true` (no dock icon). swift-tools-version: 6.0 (fall back 5.10 if
needed). No external dependencies. macOS only.

## Shared interfaces (verbatim — every stream compiles against these)

```swift
// ── Phase model (HoverEngine.swift, Stream A) ────────────────────────────
enum PanelPhase: Equatable {
    case idle
    case peeking(progress: Double)   // 0...1 dwell progress, reversible
    case open
}

final class HoverEngine: ObservableObject {
    @Published private(set) var phase: PanelPhase = .idle
    /// Wired by AppDelegate so the engine knows the open panel's live frame.
    var panelFrameProvider: (() -> NSRect?)?
    init(geometry: NotchGeometry)
    func start()
    func forceOpen()                  // --demo-open
    func requestClose()               // Esc / quit button path
}

// ── Geometry (NotchGeometry.swift, Stream A) ─────────────────────────────
struct NotchGeometry {
    let screen: NSScreen
    let notchRect: NSRect     // global coords; the physical notch band
    let hoverZone: NSRect     // notchRect inset -24pt horizontally, extending
                              // from screen top down to 14pt below menu bar bottom
    let panelAnchorX: CGFloat // notch center X
    let menuBarBottomY: CGFloat
    static func detect() -> NotchGeometry?
    // Pick the screen with safeAreaInsets.top > 0. Notch band spans
    // auxiliaryTopLeftArea.maxX → auxiliaryTopRightArea.minX, height =
    // safeAreaInsets.top. Fallback (no notch / clamshell): NSScreen.main with
    // a synthetic 200pt-wide band centered at top; app still works.
}

// ── Data (Models.swift + UsageStore.swift, Stream B) ─────────────────────
enum Severity { case normal, warning, serious, critical
    static func for(pct: Double) -> Severity  // <60 normal, <85 warning, <100 serious, else critical
}
struct MeterVM: Identifiable {
    let id: String            // "\(accountNumber)-\(label)"
    let label: String         // "5h" | "7d" | "Fable"
    let pct: Double           // 0...100, clamped
    let resetsAt: Date?
    var severity: Severity { .for(pct: pct) }
}
struct AccountVM: Identifiable {
    let id: Int               // cswap slot number
    let displayName: String   // alias ?? email local-part (before @)
    let email: String
    let isActive: Bool
    let needsRelogin: Bool    // usageStatus == "relogin_required"
    let isStale: Bool         // usage was null → values from lastGoodUsage
    let meters: [MeterVM]     // always ordered 5h, 7d, then scoped by name
}
final class UsageStore: ObservableObject {
    @Published private(set) var accounts: [AccountVM] = []
    @Published private(set) var activeNumber: Int? = nil
    @Published private(set) var lastUpdated: Date? = nil
    @Published private(set) var fetchError: String? = nil
    func start()          // fetch now, then every 60s; also DispatchSource
                          // .write watch on the daemon log, debounced 2s → refresh
    func refreshNow()
}
// Fetch = Process(~/.local/bin/cswap, ["list","--json"]),
// 10s kill timeout, background queue, publish on main. stdout may contain a
// leading upgrade-notice line — decode from the first '{' onward. On any
// failure keep previous accounts and set fetchError; NEVER blank the panel.

// ── Snapshot (Snapshot.swift, Stream B) ──────────────────────────────────
@MainActor enum Snapshot {
    /// Renders PanelContent (open state, live store data) to a PNG at 2x.
    /// Waits up to 8s for the first successful fetch. Used by --snapshot.
    static func write(store: UsageStore, to path: String) async -> Bool
}

// ── UI root (MorphShell.swift, Stream C) ─────────────────────────────────
struct MorphShell: View {
    @ObservedObject var engine: HoverEngine
    @ObservedObject var store: UsageStore
    var onQuit: () -> Void
    // Renders the notch-extension morph per engine.phase (details below).
}
```

`main.swift` flags: `--demo-open` (launch straight to open), `--snapshot <path>`
(headless render → PNG → print `SNAPSHOT OK`/`SNAPSHOT FAIL` → exit 0/1),
default = normal hover app. AppDelegate: `.accessory` activation policy, builds
geometry → store → engine → HostWindow, `store.start()`, `engine.start()`.

## HostWindow (Stream A)

One borderless, non-activating `NSPanel` subclass, ALWAYS present:
- Frame: fixed, centered on `panelAnchorX`, top flush with screen top;
  size 480 × 600 (max panel bounds + shadow slack). Never animate the frame.
- `backgroundColor .clear`, `isOpaque false`, `hasShadow false`,
  `level .statusBar`, collectionBehavior `[.canJoinAllSpaces, .stationary,
  .fullScreenAuxiliary]`, `isFloatingPanel true`, `becomesKeyOnlyIfNeeded true`.
- `ignoresMouseEvents = true` in `.idle`/`.peeking`; `false` only when `.open`
  (AppDelegate observes phase; open panel must receive scroll + clicks).
- Content: `NSHostingView(rootView: MorphShell(...))` with `.clear` background.
- Esc (`cancelOperation`) → `engine.requestClose()`.

## HoverEngine behavior (Stream A) — the feel lives here

Poll `NSEvent.mouseLocation` on a main-queue Timer: 20 Hz in `.idle`,
60 Hz while `.peeking`/`.open`.

- `.idle` + cursor enters `hoverZone` → `.peeking(0)`.
- `.peeking`: progress += dt/0.55 while inside (slow build);
  progress -= dt/0.28 while outside (faster melt-back). Reach 1 → `.open`.
  Reach 0 → `.idle`. Progress publishes every tick; SwiftUI maps it directly —
  the peek must track the dwell interruptibly, no fire-and-forget animation.
- `.open`: closes when cursor stays outside `hoverZone ∪ panelFrame`
  (panelFrame from `panelFrameProvider`, inset -8pt slack) for a 0.45s
  grace period, or on `requestClose()`. Close → `.idle` (SwiftUI animates
  the collapse; no `.closing` case needed).
- Re-entering the zone during grace cancels the close.

## The morph (Stream C) — exact visual contract

All geometry in ONE shape so it reads as the notch physically stretching.
Anchor: top-center, fused with the notch. The shape is an
`UnevenRoundedRectangle` with top radii 0 (flush into the notch/menu bar) and
animatable bottom radii.

- **idle** — nothing rendered (window is click-through).
- **peeking(p)** with eased `t = easeInOutCubic(p)`:
  - width: notchWidth → notchWidth + 24 · t
  - height below menu bar: 0 → 22 · t
  - bottom corner radius: 8 → 14 · t-lerp
  - fill: pure black (`Color.black`) — it IS the notch, seamless; no material,
    no border. A faint white glow (opacity 0.10 · t, blur 6) hints activation.
  - This stage is driven DIRECTLY by p (no implicit animation on the shape—
    bind values to p so scrubbing the hover scrubs the shape).
- **peek → open pop**: `withAnimation(.spring(response: 0.36, dampingFraction: 0.72))`
  the shape expands to the panel: width 396, height ≈ 64 + rows + footer
  (fit content, cap 560), bottom radius 28. THE QUICK LIQUID POP — this spring
  is the payoff after the slow build.
  - Fill crossfades black → liquid glass over the first 120ms of the pop:
    macOS 26 `glassEffect(.regular.tint(Color.black.opacity(0.55)), in: shape)`;
    fallback `.ultraThinMaterial` + black 0.45 overlay. Hairline white 0.08
    border on the bottom edge only.
  - Content (`PanelContent`) fades/blurs in slightly AFTER the shape lands:
    opacity 0→1, blur 6→0, delay 0.08s, duration 0.22s.
- **open → close**: content fades out 0.10s, shape springs back
  (`.spring(response: 0.28, dampingFraction: 0.86)`) to the peek silhouette
  and on to nothing; window returns to click-through.
- Shadow: `.shadow(color: .black.opacity(0.45), radius: 24, y: 10)` only
  while open (fade with the pop).

## Panel content (Stream C)

Width 396, dark glass. All text wears ink tokens, never meter colors
(`Ink.primary` white, `.secondary` white 0.62, `.muted` white 0.40).

- **Header** (h 44): "Claude Limits" 13pt semibold primary · right-aligned:
  relative "updated 12s ago" 10pt muted (TimelineView, ticks each second) ·
  refresh arrow button (borderless, calls `store.refreshNow()`) · quit
  `xmark.circle.fill` 11pt muted → `onQuit()`.
- **Account rows** (one per account, order = slot number, h ≈ 58, separated by
  white 0.06 hairlines):
  - Left block (~128pt): displayName 12pt semibold primary (active account
    also gets a 6pt system-green dot before the name); under it the org name
    10pt muted. If `needsRelogin`: replace org with
    `exclamationmark.triangle.fill` + "relogin needed" 10pt in critical color
    (icon + label — color never alone). If `isStale`: append "stale" 9pt muted.
  - Right block: the three meters in a fixed-width HStack, each:
    label ("5h"/"7d"/"Fable") 9pt muted, bar, pct.
- **MeterBar**: track = Capsule white 0.12, 64 × 4pt. Fill = Capsule, width
  pct%, min 4pt when pct > 0, height 4pt. Colors by `Severity`:
  normal → white 0.55 (quiet), warning → `#FAB219`, serious → `#EC835A`,
  critical → `#D03B3B` (validated ≥3.6:1 on dark). pct as "63%" 11pt
  monospacedDigit primary right of the bar (40pt, right-aligned).
  Under the bar: reset countdown ("2d 16h") 9pt muted, computed LIVE from
  `resetsAt` via TimelineView(.everyMinute) — never trust the cached
  countdown string. Bar fills animate `.spring(response: 0.5)` on data change.
- **Footer** (h 26): "next reset {label} · {account} · {countdown}" for the
  soonest resetsAt among ≥90% meters, else the soonest overall — 10pt muted.
  If `fetchError != nil`: swap footer for warning icon + error 10pt, serious
  color.

## Scripts (Stream B — fresh, minimal; NOT copied from any other project)

- `Scripts/bundle.sh`: `swift build -c release` (with DEVELOPER_DIR export) →
  assemble `build/NotchLimits.app` (Contents/MacOS/NotchLimits +
  Resources/Info.plist) → `codesign --force --deep -s - build/NotchLimits.app`.
- `Scripts/install.sh`: bundle.sh → `pkill -x NotchLimits || true` → rsync app
  to `/Applications/NotchLimits.app` → `open` it → optionally
  `--launch-agent` flag writes + loads
  `~/Library/LaunchAgents/com.hayden.notchlimits.plist` (RunAtLoad, KeepAlive
  false — the app is not a daemon; login relaunch only).

## Acceptance (integrator verifies ALL, in order)

1. `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build` — zero
   errors, zero warnings-as-errors.
2. `.build/debug/NotchLimits --snapshot /tmp/notchlimits-snap.png` prints
   `SNAPSHOT OK`; PNG exists, >20KB, ~792px wide (2x of 396).
3. `.build/debug/NotchLimits --demo-open` launches; `CGWindowListCopyWindowInfo`
   (via a tiny swift script or `osascript`) shows a NotchLimits window whose
   midX ≈ screen midX and top ≈ screen top; process stays alive 10s; clean
   `pkill -x NotchLimits`.
4. Normal launch: process alive 10s, zero CPU spin (ps %cpu < 5 after settle),
   no crash log in `~/Library/Logs/DiagnosticReports`.
5. `Scripts/bundle.sh` produces a signed .app that launches.
