import AppKit
import Combine

/// The three states of the notch companion. `.peeking` carries a semantic
/// TARGET — always exactly 0 (melt back toward idle) or 1 (build toward
/// open), never a continuous per-tick value. The engine only tells the view
/// where to head; SwiftUI's animation system (the render server) owns how
/// it gets there, so rendering is never coupled to this loop's tick
/// cadence — see MorphShell for the render-server-owned side.
enum PanelPhase: Equatable {
    case idle
    case peeking(target: Double)
    case open
}

/// Owns the feel: polls the global cursor position on a main-thread timer
/// and turns dwell time into `PanelPhase` transitions. Zero permissions —
/// `NSEvent.mouseLocation` only, no event taps. Publishes `phase` only on
/// real transitions — idle/peek/open changes, and a peek target flip when
/// the cursor crosses the hover-zone boundary — never on every tick; the
/// internal raw dwell math (which decides WHEN those transitions fire)
/// keeps ticking regardless, but is never itself published.
@MainActor
final class HoverEngine: ObservableObject {
    @Published private(set) var phase: PanelPhase = .idle

    /// Wired by AppDelegate once the panel exists, so `.open`'s close-grace
    /// check can include the panel's live on-screen frame.
    var panelFrameProvider: (() -> NSRect?)?

    private let geometry: NotchGeometry
    private var timer: Timer?
    private var currentHz: Double = 0
    private var lastTick: CFAbsoluteTime = 0
    private var outsideGraceElapsed: TimeInterval = 0

    /// Raw dwell fraction — internal only, NEVER published. Its only job is
    /// deciding when to cross into `.open` or back to `.idle`. The view's
    /// rendered peek animation runs on a parallel, SwiftUI-owned clock
    /// (durations deliberately matched to `buildDuration`/`decayDuration`
    /// below) so the two stay in step without being coupled — a few ms of
    /// drift between "engine decided to open" and "view finished building"
    /// is expected and invisible.
    private var rawPeekProgress: Double = 0
    private var wasInsideHoverZone = false
    /// Hover-intent gate: time the cursor has spent continuously in the
    /// hover zone while `.idle`. The peek doesn't begin until this reaches
    /// `armingDelay`, so a transit through the zone (mousing across the top,
    /// dragging a window) renders nothing at all — no build-and-melt
    /// flicker. Any exit resets it.
    private var armingElapsed: TimeInterval = 0

    private static let idleHz: Double = 20
    private static let activeHz: Double = 60
    private static let armingDelay: TimeInterval = 0.20     // idle -> peek intent gate
    private static let buildDuration: TimeInterval = 0.55   // idle -> open dwell
    private static let decayDuration: TimeInterval = 0.28   // melt-back out of zone
    private static let closeGrace: TimeInterval = 0.45      // open -> idle grace
    private static let panelSlack: CGFloat = -8             // expands panelFrame

    init(geometry: NotchGeometry) {
        self.geometry = geometry
    }

    func start() {
        lastTick = CFAbsoluteTimeGetCurrent()
        reschedule(hz: Self.idleHz)
    }

    /// `--demo-open`: jump straight to `.open` without a dwell build.
    func forceOpen() {
        outsideGraceElapsed = 0
        phase = .open
        reschedule(hz: Self.activeHz)
    }

    /// Esc key and the quit button both route here. Snaps straight to
    /// `.idle` — SwiftUI animates the visual collapse from the phase change,
    /// there is no engine-side `.closing` state.
    func requestClose() {
        outsideGraceElapsed = 0
        rawPeekProgress = 0
        wasInsideHoverZone = false
        phase = .idle
        reschedule(hz: Self.idleHz)
    }

    private func reschedule(hz: Double) {
        guard hz != currentHz else { return }
        currentHz = hz
        timer?.invalidate()
        let t = Timer(timeInterval: 1.0 / hz, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tick()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        let now = CFAbsoluteTimeGetCurrent()
        let dt = now - lastTick
        lastTick = now

        let location = NSEvent.mouseLocation
        let insideHoverZone = geometry.hoverZone.contains(location)

        switch phase {
        case .idle:
            if insideHoverZone {
                armingElapsed += dt
                if armingElapsed >= Self.armingDelay {
                    armingElapsed = 0
                    rawPeekProgress = 0
                    wasInsideHoverZone = true
                    phase = .peeking(target: 1)
                    reschedule(hz: Self.activeHz)
                }
            } else {
                armingElapsed = 0
            }

        case .peeking:
            if insideHoverZone {
                rawPeekProgress += dt / Self.buildDuration
            } else {
                rawPeekProgress -= dt / Self.decayDuration
            }

            // Edge-triggered: publish a new target ONLY when the zone
            // membership actually flips, not every tick.
            if insideHoverZone != wasInsideHoverZone {
                wasInsideHoverZone = insideHoverZone
                phase = .peeking(target: insideHoverZone ? 1 : 0)
            }

            if rawPeekProgress >= 1 {
                outsideGraceElapsed = 0
                phase = .open
            } else if rawPeekProgress <= 0 {
                rawPeekProgress = 0
                phase = .idle
                reschedule(hz: Self.idleHz)
            }

        case .open:
            let panelFrame = panelFrameProvider?()?.insetBy(dx: Self.panelSlack, dy: Self.panelSlack)
            let insidePanel = panelFrame.map { $0.contains(location) } ?? false

            if insideHoverZone || insidePanel {
                outsideGraceElapsed = 0
            } else {
                outsideGraceElapsed += dt
                if outsideGraceElapsed >= Self.closeGrace {
                    outsideGraceElapsed = 0
                    rawPeekProgress = 0
                    wasInsideHoverZone = false
                    phase = .idle
                    reschedule(hz: Self.idleHz)
                }
            }
        }
    }
}
