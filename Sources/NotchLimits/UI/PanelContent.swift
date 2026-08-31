import SwiftUI

/// The open-state panel content: header, account rows, footer. Laid out at
/// its natural intrinsic height (MorphShell owns the height cap and clips to
/// it; Snapshot renders this view uncapped for a full capture). `width`
/// tracks the wrap shape's actual open width (`notchWidth + 220`), since
/// that varies by machine. `notchHeight` insets all content below the
/// physical notch band (also machine-varying) so nothing ever sits above
/// the cutout — the band beside/around the notch stays pure contentless
/// glass.
@MainActor
struct PanelContent: View {
    @ObservedObject var store: UsageStore
    var onQuit: () -> Void = {}
    var width: CGFloat = 396
    var notchHeight: CGFloat = 32
    /// Vertical space available for the account list (panel cap minus
    /// header/footer). nil = lay out naturally (Snapshot's uncapped path).
    /// When the rows outgrow it, the list scrolls — never clips.
    var maxListHeight: CGFloat? = nil

    static let headerHeight: CGFloat = 44
    static let footerHeight: CGFloat = 26

    var body: some View {
        VStack(spacing: 0) {
            header
            accountsList
            footer
        }
        .padding(.top, notchHeight)
        .frame(width: width)
        .fontDesign(.rounded)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            ClaudeSpark().fill(Ink.coral).frame(width: 16, height: 16)
            Text("Claude Limits")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Ink.primary)

            Spacer(minLength: 8)

            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(updatedRelativeString(now: context.date))
                    .font(.system(size: 10))
                    .foregroundStyle(Ink.muted)
                    .lineLimit(1)
            }

            Button(action: { store.refreshNow() }) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11))
                    .foregroundStyle(Ink.secondary)
            }
            .buttonStyle(.plain)

            Button(action: onQuit) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Ink.muted)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .frame(height: Self.headerHeight)
    }

    private func updatedRelativeString(now: Date) -> String {
        guard let last = store.lastUpdated else { return "" }
        let seconds = max(0, Int(now.timeIntervalSince(last)))
        if seconds < 60 { return "updated \(seconds)s ago" }
        if seconds < 3600 { return "updated \(seconds / 60)m ago" }
        return "updated \(seconds / 3600)h ago"
    }

    // MARK: - Account rows

    /// Natural (unscrolled) height of the rows stack — fixed constants, so
    /// the scroll decision is deterministic arithmetic, not measurement.
    private var naturalListHeight: CGFloat {
        let count = CGFloat(store.accounts.count)
        return count * AccountRow.height + max(0, count - 1)  // rows + 1pt separators
    }

    @ViewBuilder
    private var accountsList: some View {
        if let cap = maxListHeight, naturalListHeight > cap {
            ScrollView(.vertical) { rowsStack }
                .frame(height: cap)
        } else {
            rowsStack
        }
    }

    private var rowsStack: some View {
        VStack(spacing: 0) {
            ForEach(Array(store.accounts.enumerated()), id: \.element.id) { index, account in
                AccountRow(account: account)
                if index < store.accounts.count - 1 {
                    Rectangle()
                        .fill(Color.white.opacity(0.06))
                        .frame(height: 1)
                        .padding(.horizontal, 16)
                }
            }
        }
    }

    // MARK: - Footer

    /// Soonest resetsAt among ≥90% meters; else the soonest overall.
    private var footerReset: (label: String, accountName: String, resetsAt: Date)? {
        let candidates = store.accounts.flatMap { account in
            account.meters.filter { $0.resetsAt != nil }.map { (meter: $0, account: account) }
        }
        let critical = candidates.filter { $0.meter.pct >= 90 }
        let pool = critical.isEmpty ? candidates : critical
        guard let soonest = pool.min(by: { $0.meter.resetsAt! < $1.meter.resetsAt! }) else { return nil }
        return (soonest.meter.label, soonest.account.displayName, soonest.meter.resetsAt!)
    }

    private var footer: some View {
        Group {
            if let error = store.fetchError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Ink.color(for: .serious))
                    Text(error)
                        .font(.system(size: 10))
                        .foregroundStyle(Ink.color(for: .serious))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                }
            } else if let reset = footerReset {
                TimelineView(.everyMinute) { context in
                    HStack(spacing: 0) {
                        Text("next reset \(reset.label) · \(reset.accountName) · \(Countdown.string(until: reset.resetsAt, now: context.date))")
                            .font(.system(size: 10))
                            .foregroundStyle(Ink.muted)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 0)
                    }
                }
            } else {
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: Self.footerHeight)
    }
}
