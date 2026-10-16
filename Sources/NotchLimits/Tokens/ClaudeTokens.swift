import Foundation

/// Claude Code transcripts. Every session, subagent and workflow agent
/// writes one JSONL file somewhere under a config dir's `projects/`, and one
/// API response becomes one line per content block, each repeating the same
/// `(message.id, requestId)` and a usage block. Early lines carry a
/// placeholder output count and the last line the final one, so a response
/// is worth the largest usage any of its lines reports, counted once per
/// file (one response in 233,465 ever showed up in two files).
enum ClaudeTokens: TokenSource {
    static let id = "claude"

    /// The responses this file touched most recently, newest last, with the
    /// tokens already counted for each. A response's lines are adjacent
    /// unless parallel tool calls interleave them (at most 5 other responses
    /// in between over 240,000 repeats measured), so 16 entries dedupe
    /// exactly and keep the persisted ledger small.
    struct FileState: Codable, Sendable {
        var keys: [UInt64] = []
        var counted: [Int64] = []
    }

    /// Every place a Claude Code install keeps transcripts on a Mac:
    /// `$CLAUDE_CONFIG_DIR`, the default `~/.claude`, XDG, cswap's per-account
    /// `cswap run` profiles, other `~/.claude-*` config dirs, Xcode's embedded
    /// agent and Claude desktop's local agent sandboxes. Symlinked profiles
    /// (cswap `--share-history`) collapse to one real path, and a root inside
    /// another is dropped since the outer root's recursive scan covers it.
    /// `$NOTCHLIMITS_CLAUDE_DIR`, when set, replaces them all (dev runs).
    static func roots() -> [URL] {
        let env = ProcessInfo.processInfo.environment
        if let only = env["NOTCHLIMITS_CLAUDE_DIR"], !only.isEmpty {
            return existing([only])
        }
        // Claude Code finds `~` through $HOME (Node's os.homedir), so do the same.
        let home = env["HOME"] ?? NSHomeDirectory()
        var paths: [String] = []
        if let config = env["CLAUDE_CONFIG_DIR"], !config.isEmpty {
            paths.append(config + "/projects")
        }
        paths += [home + "/.claude/projects", home + "/.config/claude/projects"]
        paths += children(home + "/.claude-swap-backup/sessions").map { $0 + "/projects" }
        paths += children(home, hidden: true).filter { $0.hasPrefix(home + "/.claude-") }.map { $0 + "/projects" }
        paths.append(home + "/Library/Developer/Xcode/CodingAssistant/ClaudeAgentConfig/projects")
        paths += sandboxes(in: home + "/Library/Application Support/Claude/local-agent-mode-sessions")
        return existing(paths)
    }

    static func isLog(_ url: URL) -> Bool {
        url.pathExtension == "jsonl"
    }

    /// Claude Code moves a session's transcript and its subagent folder to
    /// another project folder when the session leaves a worktree, so the
    /// identity is the path below `projects/<project>/`: the session id plus
    /// any subagent path, unique and unchanged by that move. A file outside
    /// that layout (a dev root) is keyed by its whole path.
    static func ledgerKey(for url: URL) -> String {
        let parts = url.standardizedFileURL.pathComponents
        guard let i = parts.lastIndex(of: "projects"), i + 2 < parts.count else {
            return url.standardizedFileURL.path
        }
        return parts[(i + 2)...].joined(separator: "/")
    }

    static func newState() -> FileState {
        FileState()
    }

    static func consume(_ line: Data, state: inout FileState) -> Int64 {
        // Usage lines are 12 percent of transcript bytes; a byte scan turns
        // the rest away without parsing them.
        let candidate = line.withUnsafeBytes { contains($0, "\"usage\"") && contains($0, "\"assistant\"") }
        guard candidate, let row = try? decoder.decode(Row.self, from: line), row.type == "assistant" else {
            return 0
        }
        let usage = row.message.usage
        let tokens = Int64(usage.input_tokens ?? 0) + Int64(usage.output_tokens ?? 0)
            + Int64(usage.cache_creation_input_tokens ?? 0) + Int64(usage.cache_read_input_tokens ?? 0)
        guard tokens > 0 else { return 0 }
        guard row.message.id != nil || row.requestId != nil else { return tokens }

        var key: UInt64 = 0xcbf2_9ce4_8422_2325 // FNV-1a 64
        for byte in "\(row.message.id ?? "")\u{0}\(row.requestId ?? "")".utf8 {
            key = (key ^ UInt64(byte)) &* 0x100_0000_01b3
        }
        var before: Int64 = 0
        if let i = state.keys.firstIndex(of: key) {
            state.keys.remove(at: i)
            before = state.counted.remove(at: i)
        }
        state.keys.append(key)
        state.counted.append(max(before, tokens))
        if state.keys.count > 16 {
            state.keys.removeFirst()
            state.counted.removeFirst()
        }
        return max(0, tokens - before)
    }

    // MARK: - Private

    private static let decoder = JSONDecoder()

    /// Only the fields the count needs; the decoder skips everything else.
    private struct Row: Decodable {
        struct Message: Decodable {
            struct Usage: Decodable {
                // Real counts sit far below 4 billion; a corrupt huge or
                // negative one fails its line instead of overflowing the sum.
                let input_tokens, output_tokens, cache_creation_input_tokens, cache_read_input_tokens: UInt32?
            }
            let id: String?
            let usage: Usage
        }
        let type: String?
        let requestId: String?
        let message: Message
    }

    /// Whether `needle` occurs in `bytes`. Hops between occurrences of its
    /// first byte (a quote) with memchr and compares only there: on real
    /// transcripts that scans about 5x faster than memmem, and this scan is
    /// most of a full catch-up's CPU time.
    private static func contains(_ bytes: UnsafeRawBufferPointer, _ needle: StaticString) -> Bool {
        let count = needle.utf8CodeUnitCount
        guard let base = bytes.baseAddress, bytes.count >= count else { return false }
        let end = base + bytes.count - count + 1
        var from = base
        while from < end, let hit = memchr(from, Int32(needle.utf8Start.pointee), end - from) {
            if memcmp(hit, needle.utf8Start, count) == 0 { return true }
            from = UnsafeRawPointer(hit) + 1
        }
        return false
    }

    /// Sorted full paths of `dir`'s entries; dot entries only when asked,
    /// like a shell glob's `*`.
    private static func children(_ dir: String, hidden: Bool = false) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        return names.filter { hidden || !$0.hasPrefix(".") }.sorted().map { dir + "/" + $0 }
    }

    /// `dir/**/.claude/projects`: every non-dot directory at any depth,
    /// symlinks not followed, except inside a sandbox, whose own folders
    /// (uploads, outputs) hold no other. This runs on every slow tick, so it
    /// reads directory entries directly and never descends into the files
    /// a sandbox piles up with use.
    private static func sandboxes(in dir: String) -> [String] {
        guard let stream = opendir(dir) else { return [] }
        var names: [String] = []
        while let entry = readdir(stream) {
            guard entry.pointee.d_type == DT_DIR else { continue }
            names.append(withUnsafeBytes(of: entry.pointee.d_name) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) })
        }
        closedir(stream)
        if names.contains(".claude") { return [dir + "/.claude/projects"] }
        return names.filter { !$0.hasPrefix(".") }.sorted().flatMap { sandboxes(in: dir + "/" + $0) }
    }
}
