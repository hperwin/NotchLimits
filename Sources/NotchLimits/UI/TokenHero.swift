import SwiftUI

/// The open panel's top band: one all-time total of every Claude Code and
/// Codex token spent on this Mac, on a rolling odometer, with the split
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
    /// "65.9B", in the user's locale like the odometer's separators.
    private static let compact = IntegerFormatStyle<Int64>.number.notation(.compactName).precision(.fractionLength(0...1))

    var body: some View {
        VStack(spacing: 0) {
            // Waits for the ledger's first publish (about half a second after
            // launch): an odometer mounted before it would roll up from 0
            // instead of from what was last shown.
            if tokens.total > 0 || tokens.isCaughtUp {
                Odometer(value: tokens.total, from: tokens.lastShown ?? 0, delay: 0.3) { tokens.lastShown = $0 }
                Text("\(tokens.isCaughtUp ? "" : "counting ")tokens on this Mac · Claude \(tokens.claude.formatted(Self.compact)) · Codex \(tokens.codex.formatted(Self.compact))")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Ink.muted)
                    .lineLimit(1)
            }
        }
        .padding(.top, 8)
        .padding(.horizontal, 16)
        .frame(height: Self.height, alignment: .top)
    }
}
