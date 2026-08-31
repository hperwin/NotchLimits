import SwiftUI

/// A single usage meter: label, track/fill bar, live percentage. The reset
/// countdown lives once per account now (AccountRow's closing line) instead
/// of duplicated under every bar.
struct MeterBar: View {
    let meter: MeterVM

    private static let trackWidth: CGFloat = 56
    private static let barHeight: CGFloat = 5

    private var clampedPct: Double { min(max(meter.pct, 0), 100) }

    private var fillWidth: CGFloat {
        guard clampedPct > 0 else { return 0 }
        return max(Self.trackWidth * clampedPct / 100.0, 4)
    }

    var body: some View {
        HStack(spacing: 3) {
            Text(meter.label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(Ink.muted)
                .fixedSize()

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.12))
                    .frame(width: Self.trackWidth, height: Self.barHeight)
                Capsule()
                    .fill(Ink.color(for: meter.severity))
                    .frame(width: fillWidth, height: Self.barHeight)
                    .animation(.spring(response: 0.5), value: fillWidth)
            }

            Text("\(Int(clampedPct.rounded()))%")
                .font(.system(size: 10, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(Ink.primary)
                .fixedSize()
        }
    }
}
