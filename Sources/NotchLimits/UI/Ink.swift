import SwiftUI

/// Text ink tokens used throughout the panel. Color never carries meaning on
/// its own here — severity color lives separately in `Ink.color(for:)` and is
/// always paired with text or an icon at the call site.
enum Ink {
    static let primary = Color.white
    static let secondary = Color.white.opacity(0.62)
    static let muted = Color.white.opacity(0.40)

    /// Claude brand coral — the spark logo and active-account accents.
    static let coral = Color(red: 0xD9 / 255.0, green: 0x77 / 255.0, blue: 0x57 / 255.0)

    /// Severity → color mapping shared by MeterBar (bar fill) and any other
    /// view that needs to color-code a severity (e.g. the relogin warning).
    /// Validated ≥3.6:1 contrast on the panel's dark glass background.
    static func color(for severity: Severity) -> Color {
        switch severity {
        case .normal:
            return Color.white.opacity(0.55)
        case .warning:
            return Color(red: 0xFA / 255.0, green: 0xB2 / 255.0, blue: 0x19 / 255.0)
        case .serious:
            return Color(red: 0xEC / 255.0, green: 0x83 / 255.0, blue: 0x5A / 255.0)
        case .critical:
            return Color(red: 0xD0 / 255.0, green: 0x3B / 255.0, blue: 0x3B / 255.0)
        }
    }
}

/// The Claude spark: 8 petals radiating from a shared center point, each
/// tapering from a point at the center to a rounded tip — a native vector
/// mark, no image assets.
struct ClaudeSpark: Shape {
    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let length = min(rect.width, rect.height) / 2
        let petal = petalPath(length: length, width: length * 0.42)

        var combined = Path()
        for i in 0..<8 {
            var transform = CGAffineTransform(translationX: center.x, y: center.y)
            transform = transform.rotated(by: Double(i) * .pi / 4)
            combined.addPath(petal.applying(transform))
        }
        return combined
    }

    /// One ray: a point at the center widening to a rounded tip at `length`.
    private func petalPath(length: CGFloat, width: CGFloat) -> Path {
        let tip = width / 2
        return Path { p in
            p.move(to: .zero)
            p.addQuadCurve(to: CGPoint(x: length - tip, y: -tip), control: CGPoint(x: length * 0.55, y: -tip))
            p.addArc(center: CGPoint(x: length - tip, y: 0), radius: tip, startAngle: .degrees(-90), endAngle: .degrees(90), clockwise: false)
            p.addQuadCurve(to: .zero, control: CGPoint(x: length * 0.55, y: tip))
            p.closeSubpath()
        }
    }
}
