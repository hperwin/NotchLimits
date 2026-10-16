import Foundation

/// Codex CLI and Codex Desktop rollouts: `<CODEX_HOME>/sessions/YYYY/MM/DD`
/// and `<CODEX_HOME>/archived_sessions`, one `rollout-*.jsonl` per thread
/// segment.
///
/// Each `token_count` event carries the model call it just finished as
/// `last_token_usage`; input + output is that call's tokens, except:
/// - Replays. Forks and delegated threads re-write the parent's history in
///   one burst as their file is created, so rows stamped less than
///   `replayWindow` after the file's first line are history, not usage.
/// - Re-emissions. Codex repeats the last row on rate-limit refreshes and
///   resumes; a row whose cumulative `total_token_usage` equals the previous
///   row's adds nothing.
/// Compactions are model calls that never reach `total_token_usage`, so their
/// `latest_token_usage_record` is added once per `response_id`.
enum CodexTokens: TokenSource {
    struct FileState: Codable, Sendable {
        var started = false
        /// First line's timestamp (the session_meta line), microseconds.
        var clock: Int64?
        /// `total_token_usage` of the previous token_count row.
        var lastTotal: [Int64]?
        var compactions: Set<String> = []
    }

    static let id = "codex"
    /// Seconds after the file's first line during which rows are replayed
    /// history, not new usage.
    static let replayWindow = 1.0

    /// NOTCHLIMITS_CODEX_DIR (dev runs, harnesses) replaces both with one root.
    static func roots() -> [URL] {
        let env = ProcessInfo.processInfo.environment
        let dirs: [String]
        if let dir = env["NOTCHLIMITS_CODEX_DIR"], !dir.isEmpty {
            dirs = [dir]
        } else {
            let home = env["CODEX_HOME"].flatMap { $0.isEmpty ? nil : $0 }
                ?? ("~/.codex" as NSString).expandingTildeInPath
            dirs = [home + "/sessions", home + "/archived_sessions"]
        }
        return existing(dirs)
    }

    static func isLog(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        return name.hasPrefix("rollout-") && name.hasSuffix(".jsonl")
    }

    /// Archiving moves a rollout to archived_sessions/ under the same name.
    static func ledgerKey(for url: URL) -> String { url.lastPathComponent }

    static func newState() -> FileState { FileState() }

    static func consume(_ line: Data, state: inout FileState) -> Int64 {
        if !state.started {
            state.started = true
            let meta = try? decoder.decode(Line<Meta>.self, from: line)
            state.clock = meta?.timestamp.flatMap(micros)
            state.lastTotal = meta?.payload?.history_base?.thread_id.flatMap(lastTotal(ofSegment:))
        }
        // No reference clock, no way to tell replays from usage: skip the file.
        guard let clock = state.clock else { return 0 }
        let found = needles(in: line)
        var tokens: Int64 = 0
        if found.row, let row = row(line) {
            // In float seconds on purpose: the window was measured on float
            // timestamps, so a row right at its edge rounds the same way.
            if Double(row.time) / 1e6 - Double(clock) / 1e6 >= replayWindow, row.total != state.lastTotal {
                tokens += row.tokens
            }
            state.lastTotal = row.total
        }
        if found.compaction, let o = try? decoder.decode(Line<Compaction>.self, from: line), o.type == "compacted",
           let record = o.payload?.latest_token_usage_record, let usage = record.usage,
           state.compactions.insert(record.response_id ?? "").inserted {
            tokens += usage.tokens
        }
        return tokens
    }

    // MARK: - Lines

    // Fields keep Codex's own snake_case names: key conversion would double
    // the decode time of the rows that pass the prefilter.
    private static let decoder = JSONDecoder()

    private struct Line<Payload: Decodable>: Decodable {
        var timestamp: String?
        var type: String?
        var payload: Payload?
    }
    private struct Meta: Decodable {
        struct Base: Decodable { var thread_id: String? }
        var history_base: Base?
    }
    private struct Row: Decodable {
        struct Info: Decodable { var total_token_usage, last_token_usage: Usage? }
        var type: String?
        var info: Info?
    }
    private struct Compaction: Decodable {
        struct Record: Decodable { var response_id: String?; var usage: Usage? }
        var latest_token_usage_record: Record?
    }
    private struct Usage: Decodable {
        var input_tokens, cached_input_tokens, cache_write_input_tokens: Int64?
        var output_tokens, reasoning_output_tokens, total_tokens: Int64?
        var tokens: Int64 { (input_tokens ?? 0) + (output_tokens ?? 0) }
        var tuple: [Int64] {
            [input_tokens, cached_input_tokens, cache_write_input_tokens, output_tokens, reasoning_output_tokens, total_tokens]
                .map { $0 ?? 0 }
        }
    }

    /// Byte prefilter for the two keys that matter; almost every line stops
    /// here, undecoded. Both needles have "_" at offset 13, about 1 byte in
    /// 1,000 of rollout text, so one memchr pass finds either several times
    /// faster than memmem's bytewise search.
    private static func needles(in line: Data) -> (row: Bool, compaction: Bool) {
        line.withUnsafeBytes { raw in
            var found = (row: false, compaction: false)
            guard raw.count > 13, let base = raw.baseAddress else { return found }
            let end = base + raw.count
            var cursor = base + 13
            while cursor < end, let hit = memchr(cursor, 0x5F, cursor.distance(to: end)) {
                let start = UnsafeRawPointer(hit) - 13
                func at(_ needle: StaticString) -> Bool {
                    start.distance(to: end) >= needle.utf8CodeUnitCount
                        && memcmp(start, needle.utf8Start, needle.utf8CodeUnitCount) == 0
                }
                found.row = found.row || at(#""type":"token_count""#)
                found.compaction = found.compaction || at(#""latest_token_usage_record":{"#)
                cursor = UnsafeRawPointer(hit) + 1
            }
            return found
        }
    }

    private static func row(_ line: Data) -> (total: [Int64], tokens: Int64, time: Int64)? {
        guard let o = try? decoder.decode(Line<Row>.self, from: line), o.type == "event_msg",
              o.payload?.type == "token_count", let info = o.payload?.info,
              let total = info.total_token_usage, let last = info.last_token_usage,
              let time = o.timestamp.flatMap(micros) else { return nil }
        return (total.tuple, last.tokens, time)
    }

    /// "2026-07-13T21:04:20.590Z" to microseconds since 1970, exactly as
    /// strptime("%Y-%m-%dT%H:%M:%S.%fZ") reads it, without a formatter per row.
    private static func micros(_ text: String) -> Int64? {
        let b = Array(text.utf8)
        guard (22...27).contains(b.count), b[4] == 0x2D, b[7] == 0x2D, b[10] == 0x54, b[13] == 0x3A,
              b[16] == 0x3A, b[19] == 0x2E, b[b.count - 1] == 0x5A else { return nil }
        func number(_ range: Range<Int>) -> Int64? {
            var value: Int64 = 0
            for i in range {
                guard (0x30...0x39).contains(b[i]) else { return nil }
                value = value * 10 + Int64(b[i] - 0x30)
            }
            return value
        }
        guard let year = number(0..<4), let month = number(5..<7), let day = number(8..<10),
              let hour = number(11..<13), let minute = number(14..<16), let second = number(17..<19),
              var fraction = number(20..<b.count - 1) else { return nil }
        for _ in b.count..<27 { fraction *= 10 }
        // Days since 1970-01-01 in the proleptic Gregorian calendar (Hinnant).
        let y = month <= 2 ? year - 1 : year
        let era = y / 400, yearOfEra = y - era * 400
        let dayOfYear = (153 * ((month + 9) % 12) + 2) / 5 + day - 1
        let days = era * 146_097 + yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear - 719_468
        return (((days * 24 + hour) * 60 + minute) * 60 + second) * 1_000_000 + fraction
    }

    // MARK: - Rotated segments

    /// A long thread continues in a new segment file whose session_meta names
    /// the previous segment (`history_base`), and its cumulative counter keeps
    /// running. Resuming re-emits the previous segment's last row into the new
    /// file, so the re-emission check starts from that segment's last total,
    /// carried per thread. The previous segment is finished by the time the
    /// next exists; this reads it once per segment file.
    private static func lastTotal(ofSegment id: String) -> [Int64]? {
        var id = id
        for _ in 0..<16 { // links followed, a guard against a cycle
            guard let url = log(endingWith: id),
                  let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return nil }
            var next: String?
            let total = data.withUnsafeBytes { raw -> [Int64]? in
                var end = raw.count
                while end > 0 {
                    var start = end
                    while start > 0, raw[start - 1] != 0x0A { start -= 1 }
                    let line = Data(bytes: raw.baseAddress! + start, count: end - start)
                    if needles(in: line).row, let total = row(line)?.total { return total }
                    if start == 0 {
                        next = (try? decoder.decode(Line<Meta>.self, from: line))?.payload?.history_base?.thread_id
                    }
                    end = start - 1
                }
                return nil
            }
            guard total == nil, let previous = next else { return total }
            id = previous
        }
        return nil
    }

    private static func log(endingWith id: String) -> URL? {
        for root in roots() {
            let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
            while let url = files?.nextObject() as? URL {
                if url.lastPathComponent.hasSuffix(id + ".jsonl"), isLog(url) { return url }
            }
        }
        return nil
    }
}
