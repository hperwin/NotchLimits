import SwiftUI
import AppKit

// A per-digit odometer (geneva carry, soft mask, lock glow): a new digit
// rises in from below, the higher a column the earlier it lands, the roll
// lands on the literal value, then a short glow. The whole display is ONE
// monotone Double `v` and every column is a pure function of it, so the
// reading can never pass the target or step back, whatever the cadence.

/// The odometer's measured reel curve (REEL_N): 69 knots at k = 146...214
/// (k counts reference frames at 60 per second, so a roll from rest lasts
/// 68 k = 1.133 s), value 0...3200, evaluated with a monotone spline
/// (mean-secant tangents, end secants at the ends, then the Fritsch-Carlson
/// limit applied in place, in order).
enum OdometerReel {
    static let start = 146.0, land = 214.0, fps = 60.0

    private static let knots: [Double] = [
        0.00, 1.17, 4.93, 11.52, 21.38, 35.00, 52.90, 75.85,
        104.72, 140.72, 185.38, 240.72, 309.50, 395.38, 503.38, 639.23,
        807.53, 1005.55, 1217.55, 1421.60, 1604.25, 1762.90, 1900.00, 2019.50,
        2124.20, 2216.90, 2299.65, 2374.03, 2441.33, 2502.55, 2558.45, 2609.75,
        2656.90, 2700.35, 2740.60, 2777.85, 2812.40, 2844.25, 2874.35, 2902.12,
        2927.97, 2952.07, 2974.50, 2995.38, 3014.85, 3032.93, 3049.78, 3065.38,
        3079.90, 3093.30, 3105.72, 3117.22, 3127.70, 3137.38, 3146.25, 3154.25,
        3161.57, 3168.00, 3173.97, 3179.00, 3183.78, 3187.72, 3191.07, 3193.88,
        3196.10, 3197.82, 3199.03, 3199.75, 3200.00,
    ]

    private static let tangents: [Double] = {
        let d = zip(knots.dropFirst(), knots).map { $0 - $1 }   // secants; knots are 1 k apart
        var m = [d[0]] + zip(d, d.dropFirst()).map { $0 * $1 <= 0 ? 0 : ($0 + $1) / 2 } + [d[d.count - 1]]
        for i in d.indices {
            if d[i] == 0 { m[i] = 0; m[i + 1] = 0; continue }
            let a = m[i] / d[i], b = m[i + 1] / d[i], h = a * a + b * b
            if h > 9 { let s = 3 / h.squareRoot(); m[i] = s * a * d[i]; m[i + 1] = s * b * d[i] }
        }
        return m
    }()

    /// Roll progress 0...1 at frame k: 0 before the start, 1 from the landing.
    static func shape(_ k: Double) -> Double {
        guard k > start else { return 0 }
        guard k < land else { return 1 }
        let i = Int(k - start), t = k - start - Double(i), t2 = t * t, t3 = t2 * t
        return ((2 * t3 - 3 * t2 + 1) * knots[i] + (t3 - 2 * t2 + t) * tangents[i]
              + (3 * t2 - 2 * t3) * knots[i + 1] + (t3 - t2) * tangents[i + 1]) / 3200
    }

    /// d shape / dk (the right derivative at the start), for velocity matching.
    static func slope(_ k: Double) -> Double {
        guard k >= start, k < land else { return 0 }
        let i = Int(k - start), t = k - start - Double(i), t2 = t * t
        return ((6 * t2 - 6 * t) * (knots[i] - knots[i + 1]) + (3 * t2 - 4 * t + 1) * tangents[i]
              + (3 * t2 - 2 * t) * tangents[i + 1]) / 3200
    }
}

/// Where `v` is at any time t, given the targets seen so far; no clock of its
/// own. A new higher target rolls from the CURRENT continuous v and enters the
/// curve at the first k0 where the roll's own speed reaches the speed v
/// already has (k0 = 146 from rest: the full signature roll), so value and
/// speed stay continuous through any cadence and the roll lands exactly on
/// the integer target at k214. Targets at or below the current one are
/// ignored: forward only. The lock glow runs on its own clock from each
/// landing, so a retarget during the pulse does not cut it, and fires at
/// most once per 5 s so a counter that lands every couple of seconds does
/// not flicker.
struct OdometerMotion {
    static let glowSeconds = (225.5 - OdometerReel.land) / OdometerReel.fps   // 0.19 s
    private(set) var target: Double
    private var v0: Double, distance = 0.0, k0 = OdometerReel.start, t0: TimeInterval = 0
    private var pulse = -TimeInterval.infinity   // landing that last fired the glow

    init(value: Double) { target = value; v0 = value }

    /// When the current roll lands (k214); nil before the first roll.
    var landing: TimeInterval? { distance > 0 ? t0 + (OdometerReel.land - k0) / OdometerReel.fps : nil }

    /// From this time nothing moves: v has landed and the glow is over.
    var quiet: TimeInterval { max(landing ?? -.infinity, glowStart + Self.glowSeconds) }

    private var glowStart: TimeInterval {
        guard let landing, landing - pulse >= 5 else { return pulse }
        return landing
    }

    private func frame(_ t: TimeInterval) -> Double { k0 + max(0, t - t0) * OdometerReel.fps }

    func value(at t: TimeInterval) -> Double {
        let k = frame(t)
        guard distance > 0, k < OdometerReel.land else { return target }
        let s0 = OdometerReel.shape(k0)
        return min(target, v0 + distance * (OdometerReel.shape(k) - s0) / (1 - s0))
    }

    /// Value units per k.
    private func speed(at t: TimeInterval) -> Double {
        let k = frame(t)
        guard distance > 0, k < OdometerReel.land else { return 0 }
        return distance * OdometerReel.slope(k) / (1 - OdometerReel.shape(k0))
    }

    /// The lock glow: rises over k213.5...216.5, eases out by k225.5.
    func glow(at t: TimeInterval) -> Double {
        let k = OdometerReel.land + (t - glowStart) * OdometerReel.fps
        return smooth((k - 213.5) / 3) * (1 - smooth((k - 216.5) / 9))
    }

    mutating func retarget(to newTarget: Double, at now: TimeInterval) {
        guard newTarget > target else { return }
        let t = max(now, t0)   // a roll still waiting out its start delay keeps that start
        if let landing, landing <= t { pulse = glowStart }
        let v = value(at: t), u = speed(at: t), d = newTarget - v
        // First k whose hazard s'/(1 - s) carries d at speed u; it always exists
        // before k214 because the hazard grows without bound there.
        var k = OdometerReel.start
        while k < 213.9, d * OdometerReel.slope(k) / (1 - OdometerReel.shape(k)) < u { k += 0.05 }
        v0 = v; distance = d; target = newTarget; t0 = t; k0 = k
    }
}

/// Smoothstep, clamped to 0...1.
private func smooth(_ x: Double) -> Double { let x = min(max(x, 0), 1); return x * x * (3 - 2 * x) }

/// A live odometer for an integer that only grows. Rolls from `from` to
/// `value` on appear (after `delay`, so a fade-in does not eat the start of
/// the roll), retargets on every change of `value`, and hands the value it
/// shows to `onSettle` when a roll settles and when the view goes away
/// (floor of v, so the next mount continues from what was seen).
/// The TimelineView is paused whenever nothing moves, so an idle odometer
/// draws no frames at all, and otherwise ticks at the reel curve's 60 per
/// second: a 120 Hz display would only double the cost.
struct Odometer: View {
    let value: Int64
    let delay: TimeInterval
    let onSettle: (Int64) -> Void
    @State private var motion: OdometerMotion
    @State private var live = false

    init(value: Int64, from: Int64, delay: TimeInterval, onSettle: @escaping (Int64) -> Void) {
        self.value = value; self.delay = delay; self.onSettle = onSettle
        _motion = State(initialValue: OdometerMotion(value: Double(from)))
    }

    private static var now: TimeInterval { Date.now.timeIntervalSinceReferenceDate }

    var body: some View {
        let face = Face(size: 26, ink: Ink.primary)
        TimelineView(.animation(minimumInterval: 1 / OdometerReel.fps, paused: !live)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let v = live ? motion.value(at: t) : motion.target, glow = live ? motion.glow(at: t) : 0
            Canvas { ctx, box in face.draw(&ctx, box, v: v, glow: glow) }
        }
        .frame(height: face.height)
        .onAppear { roll(to: value, at: Self.now + delay) }
        .onChange(of: value) { _, new in roll(to: new, at: Self.now) }
        .task(id: motion.target) {
            try? await Task.sleep(for: .seconds(max(0, motion.quiet - Self.now)))
            guard !Task.isCancelled else { return }
            live = false
            onSettle(Int64(motion.target))
        }
        .onDisappear { onSettle(Int64(motion.value(at: Self.now).rounded(.down))) }
    }

    private func roll(to new: Int64, at t: TimeInterval) {
        guard Double(new) > motion.target else { return }
        motion.retarget(to: Double(new), at: t)
        live = true
    }
}

extension Odometer {
    /// The pure drawing path: one frame for a given v and glow, no clock, so
    /// ImageRenderer and harnesses can draw any frame. Geometry is in the
    /// reel design's units (the '0' ink is 43 px wide, reel pitch 98 px,
    /// cells 2 px tighter than the tabular advance, separators as wide as
    /// their ink plus the digits' side bearing), measured on the real face
    /// with Core Text so any locale's separator gets its own width.
    struct Face: Sendable {
        static let halo = Ink.coral.mix(with: .white, by: 0.2, in: .device)   // #E09470, from our coral
        let size: CGFloat, ink: Color, font: Font, separator: String
        let pitch, advance, cell, ascent, descent, sepWidth, sepOrigin: CGFloat
        /// Ink box + 0.04 em, plus the 0.16 em feather, above and below.
        var height: CGFloat { ascent + descent + 0.4 * size }

        /// The 11 glyphs, resolved on the first frame and reused by the rest:
        /// resolving text is most of a frame's cost, and a Face lives only
        /// until the next value. Canvas draws on the main thread only.
        private final class Cache: @unchecked Sendable { var texts: [GraphicsContext.ResolvedText] = [] }
        private let cache = Cache()

        init(size: CGFloat, ink: Color) {
            let separator = Locale.current.groupingSeparator ?? ","
            let tabular = NSFont.monospacedDigitSystemFont(ofSize: size, weight: .bold)
            let ns = tabular.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) } ?? tabular
            func line(_ s: String) -> CTLine { CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: [.font: ns])) }
            func width(_ s: String) -> CGFloat { CGFloat(CTLineGetTypographicBounds(line(s), nil, nil, nil)) }
            let zero = CTLineGetImageBounds(line("0"), nil), digits = CTLineGetImageBounds(line("0123456789"), nil)
            let sep = CTLineGetImageBounds(line(separator), nil), px = zero.width / 43
            self.size = size; self.ink = ink; self.separator = separator
            font = .system(size: size, weight: .bold, design: .rounded).monospacedDigit()
            pitch = 98 * px
            advance = width("0")
            cell = advance - 2 * px
            // The mask window spans the ink of the digits and the separator (the
            // comma's tail, an apostrophe's top); a space separator has no ink.
            let side = (cell - zero.width) / 2, inked = !sep.isNull && sep.width > 0
            ascent = max(digits.maxY, inked ? sep.maxY : 0)
            descent = max(-digits.minY, inked ? -sep.minY : 0)
            sepWidth = inked ? sep.width + 2 * side : width(separator)
            sepOrigin = inked ? side - sep.minX : 0
        }

        func draw(_ ctx: inout GraphicsContext, _ box: CGSize, v: Double, glow: Double) {
            let v = max(v, 0), whole = Int64(v), frac = v - Double(whole)
            // Geneva columns, least significant first: column c reads floor(v / 10^c)
            // and turns (by frac) only while every digit below it is 9. A leading
            // column is blank until its reel leaves 0 and opens with that first
            // step, its separator with it (reflow step, anchor center).
            var cols: [(reel: Int64, frac: Double, open: CGFloat)] = []
            var p: Int64 = 1
            while cols.count < 18, cols.isEmpty || whole >= p || (whole == p - 1 && frac > 0) {
                let f = whole % p == p - 1 ? frac : 0
                cols.append((whole / p, f, cols.isEmpty ? 1 : CGFloat(min(1, Double(whole / p) + f))))
                p *= 10
            }
            let scale = ctx.environment.displayScale
            func snap(_ x: CGFloat) -> CGFloat { (x * scale).rounded() / scale }
            func hasSeparator(_ c: Int) -> Bool { c > 0 && c % 3 == 0 }
            let width = cols.indices.reduce(0) { $0 + cols[$1].open * (cell + (hasSeparator($1) ? sepWidth : 0)) }
            let baseline = snap(0.2 * size + ascent)
            var x = snap((box.width - width) / 2)
            var glyphs: [(text: Int, x: CGFloat, y: CGFloat, alpha: Double)] = []   // text origins; 10 = separator
            for c in cols.indices.reversed() {
                let col = cols[c], w = cell * col.open, digit = Int(col.reel % 10), left = x + (w - advance) / 2
                if c == 0 || col.reel > 0 { glyphs.append((digit, left, baseline - CGFloat(col.frac) * pitch, 1)) }
                if col.frac > 1e-4 { glyphs.append(((digit + 1) % 10, left, baseline + CGFloat(1 - col.frac) * pitch, 1)) }
                x += w
                if hasSeparator(c) { glyphs.append((10, x + sepOrigin, baseline, Double(col.open))); x += sepWidth * col.open }
            }

            if cache.texts.isEmpty {
                cache.texts = (0...9).map { ctx.resolve(Text(String($0)).font(font)) } + [ctx.resolve(Text(separator).font(font))]
            }
            let texts = cache.texts, top = texts[0].firstBaseline(in: CGSize(width: 1000, height: 1000))
            // Soft mask: opaque over the ink box + 0.04 em, a 0.16 em smoothstep
            // feather beyond, nothing outside; destinationIn over the whole layer,
            // since it only touches pixels the fill covers.
            let feather = 0.16 * size / height
            let ramp = (0...8).map { (alpha: smooth(Double($0) / 8), at: feather * CGFloat($0) / 8) }
            let mask = Gradient(stops: ramp.map { .init(color: .black.opacity($0.alpha), location: $0.at) }
                + ramp.reversed().map { .init(color: .black.opacity($0.alpha), location: 1 - $0.at) })
            let windowTop = baseline - ascent - 0.2 * size
            func layer(_ l: inout GraphicsContext, _ color: Color) {
                for g in glyphs {
                    var text = texts[g.text]
                    text.shading = .color(color.opacity(g.alpha))
                    l.draw(text, at: CGPoint(x: g.x, y: g.y - top), anchor: .topLeading)
                }
                l.blendMode = .destinationIn
                l.fill(Path(CGRect(origin: .zero, size: box).insetBy(dx: -box.height, dy: -box.height)),
                       with: .linearGradient(mask, startPoint: CGPoint(x: 0, y: windowTop), endPoint: CGPoint(x: 0, y: windowTop + height)))
            }
            // Lock glow: the masked digits in the halo coral, blurred, under the
            // ink, which itself warms toward the coral at the peak.
            if glow > 0.001 {
                ctx.drawLayer { halo in
                    halo.opacity = 0.6 * glow
                    halo.addFilter(.blur(radius: 0.08 * size))
                    halo.drawLayer { layer(&$0, Self.halo) }
                }
            }
            ctx.drawLayer { layer(&$0, glow > 0.001 ? ink.mix(with: Self.halo, by: 0.5 * glow, in: .device) : ink) }
        }
    }
}
