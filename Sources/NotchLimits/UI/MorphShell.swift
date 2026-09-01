import SwiftUI

private func lerp(_ a: CGFloat, _ b: CGFloat, _ t: Double) -> CGFloat {
    a + (b - a) * CGFloat(t)
}

private func roundedRect(_ rect: CGRect, top: CGFloat, bottom: CGFloat) -> Path {
    UnevenRoundedRectangle(topLeadingRadius: top, bottomLeadingRadius: bottom, bottomTrailingRadius: bottom, topTrailingRadius: top)
        .path(in: rect)
}

/// The v1.1 open-state shape: a glass slab that wraps around the physical
/// notch, cut out via an even-odd interior rect so the notch band sits
/// inside the glass. One scalar drives the whole thing: `morph` runs
/// -1 (collapsed to nothing) → 0 (the peek dwell's built silhouette,
/// numerically identical to v1's peek(1)) → 1 (fully open) — so the dwell
/// build, the pop, and the close all read as one continuous liquid motion.
/// `animatableData` is `morph` itself — a real, single-scalar `Animatable`
/// conformance. Every other input (`notchWidth`, `notchHeight`) is a fixed
/// per-session constant, never something that varies mid-animation, so one
/// scalar is enough: `path(in:)` gets called with render-server-
/// interpolated `morph` values at every displayed frame, not just once per
/// published state change.
struct NotchWrapShape: Shape {
    enum Part { case outer, cutout, outerMinusCutout }

    var morph: Double
    let notchWidth: CGFloat
    let notchHeight: CGFloat
    var part: Part = .outer

    var animatableData: Double {
        get { morph }
        set { morph = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let popT = max(morph, 0)
        let peekT = min(max(morph + 1, 0), 1)
        let outer = roundedRect(rect, top: 18 * popT, bottom: popT > 0 ? lerp(14, 32, popT) : 8 + 6 * peekT)
        if part == .outer { return outer }

        // No cutout while peeking/closed — the peek stays a solid pill. Once
        // popping, the cutout inset lerps from "covers the whole shape top"
        // (full pill width, zero height — a no-op) to the real notch rect.
        guard popT > 0 else { return part == .cutout ? Path() : outer }
        let width = lerp(rect.width, notchWidth, popT)
        let height = lerp(0, notchHeight, popT)
        let cutRect = CGRect(x: rect.midX - width / 2, y: rect.minY, width: width, height: height)
        let cutout = roundedRect(cutRect, top: 0, bottom: 12 * popT)
        if part == .cutout { return cutout }

        var combined = outer
        combined.addPath(cutout)
        return combined
    }
}

/// The wrap shape's fill + hairlines, as a pure function of `morph` — no
/// phase/engine awareness. Shared by the live `MorphShell` and the headless
/// `Snapshot` renderer so both draw the identical panel.
struct NotchWrapPanel: View {
    var morph: Double
    var notchWidth: CGFloat
    var notchHeight: CGFloat
    var glowOpacity: Double = 0
    var glassAmount: Double = 1
    var borderOpacity: Double = 1
    /// Snapshot-only: `glassEffect` has no real compositor to sample behind
    /// an offscreen `ImageRenderer`, so it rasterizes as a no-op there. Force
    /// the material fallback instead so the PNG is faithful evidence.
    var forceGlassFallback: Bool = false

    private func shape(_ part: NotchWrapShape.Part) -> NotchWrapShape {
        NotchWrapShape(morph: morph, notchWidth: notchWidth, notchHeight: notchHeight, part: part)
    }

    var body: some View {
        ZStack {
            shape(.outer).fill(Color.black).opacity(1 - glassAmount)
            glassLayer.opacity(glassAmount)
        }
        .clipShape(shape(.outerMinusCutout), style: FillStyle(eoFill: true))
        .overlay {
            shape(.outer)
                .fill(Color.white.opacity(glowOpacity))
                .blur(radius: 6)
                .allowsHitTesting(false)
        }
        .overlay {
            // Specular hairline tracing the cutout edge only — the
            // refraction cue that sells "glass warping around the notch."
            shape(.cutout)
                .stroke(Color.white.opacity(0.14), lineWidth: 1)
                .opacity(glassAmount)
        }
        .overlay(alignment: .bottom) {
            shape(.outer)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
                .opacity(borderOpacity)
        }
    }

    /// Smoothness v2: `glassEffect`'s own shape argument is a FIXED
    /// `Rectangle`, never the animating `shape(.outer)` — the outer
    /// `.clipShape` above already masks the visible silhouette on the
    /// render server, every frame. Re-deriving `NotchWrapShape.path(in:)`'s
    /// curve/cutout math a second time for the material's own geometry, on
    /// top of that clip already doing it, was redundant per-frame cost for
    /// zero visual gain — a rectangle costs nothing to resize regardless of
    /// animation rate. (Invisible during peek anyway, since `glassAmount`
    /// is 0 there; during the brief pop crossfade the material's specular
    /// highlights trace a plain rectangle for ~100ms instead of the true
    /// silhouette — a deliberate, minor trade for guaranteed smoothness,
    /// consistent with DESIGN-V1.1's "fluidity wins" rule.)
    @ViewBuilder
    private var glassLayer: some View {
        if !forceGlassFallback, #available(macOS 26.0, *) {
            Color.clear.glassEffect(.regular.tint(Color.black.opacity(0.55)), in: Rectangle())
        } else {
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                Rectangle().fill(Color.black.opacity(0.45))
            }
        }
    }
}

/// Drives `NotchWrapPanel` + `PanelContent` from `engine.phase`.
///
/// Smoothness v2: the engine publishes only semantic targets
/// (`.peeking(target:)`, `.open`, `.idle`) — never a per-tick value. Every
/// motion here is a SwiftUI-owned, interruptible animation on `morph`
/// (`.easeInOut` for the peek build/melt, the ratified springs for
/// pop/close). That's what makes `NotchWrapShape`'s real `animatableData`
/// pay off: the render server samples it at native display refresh rate,
/// fully decoupled from how often — or how evenly — the engine's own
/// dwell-tracking timer happens to tick. Retargeting `morph` again mid-
/// flight (mouse reverses direction, or the open threshold fires while the
/// peek build is still animating) blends automatically from wherever it
/// currently is; nothing here ever needs to snap a value first.
@MainActor
struct MorphShell: View {
    @ObservedObject var engine: HoverEngine
    @ObservedObject var store: UsageStore
    var onQuit: () -> Void
    /// Pushed whenever the open panel's target size changes, so HostWindow
    /// can expose the REAL panel rect for HoverEngine's stay-open hit test
    /// (the window is much taller than the panel; its frame is too coarse).
    var onOpenPanelSize: (CGSize) -> Void = { _ in }

    @State private var notchWidth: CGFloat = 200
    @State private var notchHeight: CGFloat = 32

    @State private var morph: Double = -1
    @State private var openTargetHeight: CGFloat = MorphShell.minOpenHeight
    /// Per-screen height cap, set from NotchGeometry on appear. The list
    /// inside scrolls past it — no account-count ceiling.
    @State private var maxOpenHeight: CGFloat = 560
    @State private var contentNaturalHeight: CGFloat = 0

    @State private var glassAmount: Double = 0
    @State private var contentOpacity: Double = 0
    @State private var contentBlur: CGFloat = 6

    private static let minOpenHeight: CGFloat = 320
    private static let baseContentHeight: CGFloat = 44 + 26   // header + footer
    private static let rowHeight: CGFloat = 64

    /// Mirrors HoverEngine's internal dwell build/decay durations. The two
    /// clocks are deliberately independent — the engine decides WHEN to
    /// cross into `.open` purely from its own raw-progress arithmetic; this
    /// view decides HOW the peek looks purely from these durations. Matching
    /// the numbers keeps them visually in step without coupling them; a few
    /// ms of drift is expected and invisible.
    private static let peekBuildDuration: Double = 0.55
    private static let peekDecayDuration: Double = 0.28

    private static let openSpring = Animation.spring(response: 0.36, dampingFraction: 0.72)
    private static let closeSpring = Animation.spring(response: 0.28, dampingFraction: 0.86)

    private var popT: Double { max(morph, 0) }
    private var peekT: Double { min(max(morph + 1, 0), 1) }
    private var openWidth: CGFloat { notchWidth + 220 }

    /// Peek reads as a tongue sliding out of the notch slot: it TAPERS 8pt
    /// inside each notch edge while dropping 30pt below the menu bar —
    /// never bulging past the notch, whose sharp black-on-white edges
    /// against the menu bar were the old peek's tell. The pop lerps start
    /// from these same endpoints so the peek→open handoff stays continuous.
    private var shapeWidth: CGFloat {
        popT > 0 ? lerp(notchWidth - 16, openWidth, popT) : notchWidth - 16 * peekT
    }
    private var shapeHeight: CGFloat {
        popT > 0 ? lerp(notchHeight + 30, openTargetHeight, popT) : notchHeight + 30 * peekT
    }
    private var glowOpacity: Double { popT > 0 ? 0 : 0.10 * peekT }

    /// Fix 2 (v1.2): content carries a `notchHeight` top inset (see
    /// PanelContent) so nothing renders under the cutout. Grow both bounds
    /// by that inset too, so the guaranteed ≥320pt content region still
    /// holds below the inset rather than being eaten by it.
    private var openHeightEstimate: CGFloat {
        let content = notchHeight + Self.baseContentHeight + CGFloat(store.accounts.count) * Self.rowHeight
        return min(max(content, Self.minOpenHeight + notchHeight), maxOpenHeight + notchHeight)
    }

    var body: some View {
        ZStack(alignment: .top) {
            NotchWrapPanel(
                morph: morph, notchWidth: notchWidth, notchHeight: notchHeight,
                glowOpacity: glowOpacity, glassAmount: glassAmount, borderOpacity: popT
            )
            .frame(width: shapeWidth, height: shapeHeight, alignment: .top)
            .shadow(color: Color.black.opacity(0.45 * popT), radius: 24, y: 10)

            // Mounted ONLY on the pop (contentOpacity is held at 0 through
            // idle/peek by retargetPeek, so this branch is structurally
            // absent — not just hidden — until engine.phase == .open first
            // makes it true). During peek the hierarchy above is the entire
            // tree: one NotchWrapPanel, nothing else diffs per frame.
            if contentOpacity > 0 || engine.phase == .open {
                PanelContent(
                    store: store, onQuit: onQuit, width: openWidth, notchHeight: notchHeight,
                    maxListHeight: maxOpenHeight - PanelContent.headerHeight - PanelContent.footerHeight
                )
                    .frame(width: openWidth, alignment: .top)
                    .background(heightProbe)
                    .frame(height: shapeHeight, alignment: .top)
                    .clipped()
                    .opacity(contentOpacity)
                    .blur(radius: contentBlur)
                    .allowsHitTesting(engine.phase == .open)
            }
        }
        // maxHeight too: the hosting view now spans the window's full fixed
        // height (HostWindow no longer lets content size drive the frame),
        // and without it SwiftUI would center the shape vertically in that
        // tall proposal instead of pinning it to the screen top.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear(perform: syncOnAppear)
        .onPreferenceChange(PanelHeightPreferenceKey.self) { measured in
            guard measured > 0 else { return }
            contentNaturalHeight = measured
            let target = min(max(measured, Self.minOpenHeight + notchHeight), maxOpenHeight + notchHeight)
            if engine.phase == .open {
                withAnimation(Self.openSpring) { openTargetHeight = target }
            } else {
                openTargetHeight = target
            }
        }
        .onChange(of: openTargetHeight) { _, newHeight in
            onOpenPanelSize(CGSize(width: openWidth, height: newHeight))
        }
        .onChange(of: engine.phase) { oldPhase, newPhase in
            switch newPhase {
            case .idle:
                if case .open = oldPhase {
                    closeFromOpen()
                } else {
                    morph = -1
                }
            case .peeking(let target):
                retargetPeek(to: target)
            case .open:
                openPop()
            }
        }
    }

    private var heightProbe: some View {
        GeometryReader { proxy in
            Color.clear.preference(key: PanelHeightPreferenceKey.self, value: proxy.size.height)
        }
    }

    private func syncOnAppear() {
        if let geometry = NotchGeometry.detect() {
            notchWidth = geometry.notchRect.width
            notchHeight = geometry.notchRect.height
            maxOpenHeight = geometry.maxOpenPanelHeight
        }
        openTargetHeight = openHeightEstimate
        onOpenPanelSize(CGSize(width: openWidth, height: openTargetHeight))
        switch engine.phase {
        case .idle: morph = -1
        case .peeking(let target): retargetPeek(to: target)
        case .open: openPop()
        }
    }

    /// The one entry point for peek motion. The engine hands us a
    /// destination only — 0 (melt back toward idle) or 1 (build toward
    /// open) — never a per-tick value; we animate `morph` toward the
    /// matching endpoint (-1 or 0) over a duration mirroring the engine's
    /// own dwell rate. SwiftUI (the render server) draws every intermediate
    /// frame via `NotchWrapShape`'s real `animatableData`. Calling this
    /// again mid-flight — the mouse reversing direction — retargets the
    /// SAME animated property; SwiftUI blends from morph's current
    /// interpolated value, so a direction flip reads as a soft turn, never
    /// a snap.
    private func retargetPeek(to target: Double) {
        contentOpacity = 0
        contentBlur = 6
        glassAmount = 0
        let duration = target >= 1 ? Self.peekBuildDuration : Self.peekDecayDuration
        withAnimation(.easeInOut(duration: duration)) {
            morph = target >= 1 ? 0 : -1
        }
    }

    /// The quick liquid pop: one spring carries `morph` from wherever it
    /// currently is — mid-flight on the peek's `.easeInOut` (the engine's
    /// raw threshold can fire a few ms before or after the view's own peek
    /// animation finishes; that drift is expected, see the duration
    /// constants above), or straight from -1 on `--demo-open` — up to 1.
    /// Retargeting an in-flight animated property is how SwiftUI already
    /// handles this; no manual snap is needed.
    private func openPop() {
        openTargetHeight = contentNaturalHeight > 0
            ? min(max(contentNaturalHeight, Self.minOpenHeight + notchHeight), maxOpenHeight + notchHeight)
            : openHeightEstimate
        withAnimation(Self.openSpring) { morph = 1 }
        withAnimation(.linear(duration: 0.12)) { glassAmount = 1 }
        withAnimation(.easeOut(duration: 0.22).delay(0.08)) {
            contentOpacity = 1
            contentBlur = 0
        }
    }

    /// Content out first, then one spring carries the shape back through
    /// the peek silhouette and on to nothing.
    private func closeFromOpen() {
        withAnimation(.easeIn(duration: 0.10)) {
            contentOpacity = 0
            contentBlur = 6
        }
        withAnimation(Self.closeSpring) {
            morph = -1
            glassAmount = 0
        }
    }
}

private struct PanelHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
