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
    /// Asked again every few seconds while live, so a root that appears
    /// later (a first Codex run, a new profile) is found.
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

extension TokenSource {
    /// Real paths of the candidates that are directories, first occurrence
    /// kept, minus any nested inside another (the outer one's recursive scan
    /// covers it). Real paths are what FSEvents and the kernel report.
    static func existing(_ paths: [String]) -> [URL] {
        var real: [String] = []
        for path in paths {
            guard let resolved = realpath(path, nil) else { continue }
            let dir = String(cString: resolved)
            free(resolved)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue, !real.contains(dir) {
                real.append(dir)
            }
        }
        return real.filter { dir in !real.contains { dir.hasPrefix($0 + "/") } }
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
    }
}
