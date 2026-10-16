import SwiftUI

/// The open panel's top band: one all-time total of every Claude Code and
/// Codex token spent on this Mac, on the playbook odometer, with the split
/// under it. PanelContent puts it first, inside its notch inset, so the
/// digits sit centered under the cutout; the 8 pt pad plus the odometer's
/// 0.2 em mask margin leave a visible gap below the cutout's edge. The panel
/// unmounts its content when closed, so every open rolls from
/// `tokens.lastShown` (what the user last saw, kept in the store; 0 the very
/// first time) to the live total, after the content's 0.3 s fade-in, then
/// follows each change of the total while open.
@MainActor
struct TokenHero: View {
    @ObservedObject var tokens: TokenStore
    static let height: CGFloat = 60

    var body: some View {
        VStack(spacing: 0) {
            Odometer(value: tokens.total, from: tokens.lastShown ?? 0, delay: 0.3) { tokens.lastShown = $0 }
            Text("\(tokens.isCaughtUp ? "" : "counting ")tokens on this Mac · Claude \(Self.compact(tokens.claude)) · Codex \(Self.compact(tokens.codex))")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Ink.muted)
                .lineLimit(1)
        }
        .padding(.top, 8)
        .padding(.horizontal, 16)
        .frame(height: Self.height, alignment: .top)
    }

    /// One decimal and a K/M/B/T suffix ("65.9B"); plain digits below 1,000.
    static func compact(_ n: Int64) -> String {
        var x = Double(n), unit = 0
        while x >= 999.95, unit < 4 { x /= 1000; unit += 1 }
        return unit == 0 ? "\(n)" : String(format: "%.1f", x) + ["", "K", "M", "B", "T"][unit]
    }
}
