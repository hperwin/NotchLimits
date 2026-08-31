import SwiftUI

/// One account's row: spark + name, the binding-window big percentage, the
/// meters, and a closing line — smallest countdown, or a relogin warning
/// that takes its place (last-good bars stay visible either way). Row
/// height ≈ 64; the hairline separator between rows is drawn by
/// PanelContent, which owns the list.
struct AccountRow: View {
    let account: AccountVM
    static let height: CGFloat = 64

    /// The binding window — the meter with the highest pct, since that's
    /// the one that governs when the account actually throttles.
    private var binding: MeterVM? {
        account.meters.max(by: { $0.pct < $1.pct })
    }

    /// The meter with the soonest reset, for the closing line.
    private var soonest: MeterVM? {
        account.meters.filter { $0.resetsAt != nil }.min { $0.resetsAt! < $1.resetsAt! }
    }

    private var sparkColor: Color {
        guard !account.needsRelogin, account.isActive else { return Color.white.opacity(0.22) }
        return Ink.coral
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    ClaudeSpark()
                        .fill(sparkColor)
                        .frame(width: 13, height: 13)
                        .shadow(color: Ink.coral.opacity(sparkGlow), radius: 5)
                    Text(account.displayName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Ink.primary)
                        .lineLimit(1)
                }
                HStack(spacing: 6) {
                    ForEach(account.meters) { MeterBar(meter: $0) }
                }
                closingLine
            }

            Spacer(minLength: 6)
            bigPercent
                .layoutPriority(1)
        }
        .padding(.horizontal, 10)
        .frame(height: Self.height)
        .background(account.isActive ? RoundedRectangle(cornerRadius: 12).fill(Ink.coral.opacity(0.08)) : nil)
    }

    private var sparkGlow: Double {
        account.isActive && !account.needsRelogin ? 0.5 : 0
    }

    @ViewBuilder
    private var closingLine: some View {
        if account.needsRelogin {
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(Ink.color(for: .critical))
                Text("relogin needed")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Ink.color(for: .critical))
            }
        } else if let soonest, let resetsAt = soonest.resetsAt {
            TimelineView(.everyMinute) { context in
                Text("\(soonest.label) resets in \(Countdown.string(until: resetsAt, now: context.date))\(account.isStale ? " · stale" : "")")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Ink.muted)
            }
        } else if account.isStale {
            Text("stale")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(Ink.muted)
        }
    }

    @ViewBuilder
    private var bigPercent: some View {
        if let binding {
            VStack(alignment: .trailing, spacing: 1) {
                if binding.pct >= 100 {
                    Text("FULL")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Ink.color(for: .critical))
                        .fixedSize()
                } else {
                    Text("\(Int(binding.pct.rounded()))%")
                        .font(.system(size: 17, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(binding.severity == .normal ? Ink.primary : Ink.color(for: binding.severity))
                        .fixedSize()
                }
                Text(binding.label)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Ink.muted)
                    .fixedSize()
            }
        }
    }
}
