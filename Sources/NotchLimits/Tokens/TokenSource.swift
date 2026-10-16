import Foundation

/// One family of local AI-tool logs whose token usage NotchLimits totals
/// (Claude Code transcripts, Codex rollouts). Every log is append-only
/// JSONL. `TokenStore` tails each file from its committed byte offset and
/// feeds complete lines, in file order, to `consume`, which returns the
/// tokens those lines add. Per-file parser memory lives in `FileState` and
/// is persisted in the ledger beside the offset, so a relaunch resumes
/// exactly where it left off and pruned logs keep their counted tokens.
protocol TokenSource {
    associatedtype FileState: Codable, Sendable

    /// Short stable id ("claude", "codex"): ledger section and JSON field.
    static var id: String { get }

    /// Existing directories to scan recursively and watch with FSEvents.
    static func roots() -> [URL]

    /// Whether a file found under a root is one of this source's logs.
    static func isLog(_ url: URL) -> Bool

    /// Ledger identity of a log. Must survive the file moving between roots
    /// (Codex moves rollouts from sessions/ to archived_sessions/).
    static func ledgerKey(for url: URL) -> String

    static func newState() -> FileState

    /// One complete line, without its trailing newline. Returns the tokens
    /// newly attributed by this line (>= 0).
    static func consume(_ line: Data, state: inout FileState) -> Int64
}
