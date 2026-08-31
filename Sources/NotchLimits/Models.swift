import Foundation

// View models — the shared interface the UI codes against.

enum Severity: Equatable {
    case normal, warning, serious, critical

    /// <60 normal, <85 warning, <100 serious, else critical.
    static func `for`(pct: Double) -> Severity {
        if pct < 60 { return .normal }
        if pct < 85 { return .warning }
        if pct < 100 { return .serious }
        return .critical
    }
}

struct MeterVM: Identifiable {
    let id: String            // "\(accountNumber)-\(label)"
    let label: String         // "5h" | "7d" | "Fable"
    let pct: Double           // 0...100, clamped
    let resetsAt: Date?
    var severity: Severity { .for(pct: pct) }
}

struct AccountVM: Identifiable {
    let id: Int               // cswap slot number
    var displayName: String   // alias ?? email local-part; UsageStore appends
                              // the domain when two accounts collide on it
    let email: String
    let isActive: Bool
    let needsRelogin: Bool    // usageStatus == "relogin_required"
    let isStale: Bool         // usage was null → values from lastGoodUsage
    let meters: [MeterVM]     // always ordered 5h, 7d, then scoped by name
}

// Wire schema (cswap list --json, every leaf Optional per spec). Extra live
// fields are unused here; JSONDecoder ignores unknown keys.
struct CSwapListOutput: Decodable, Sendable {
    let schemaVersion: Int?
    let activeAccountNumber: Int?
    let accounts: [CSwapAccount]?
}

struct CSwapAccount: Decodable, Sendable {
    let number: Int?
    let email: String?
    let organizationName: String?
    let alias: String?
    let active: Bool?
    let usageStatus: String?
    let usage: CSwapUsage?
    let lastGoodUsage: CSwapUsage?
    let usageFetchedAt: String?
    let usageAgeSeconds: Double?
    let lastGoodFetchedAt: String?
    let lastGoodAgeSeconds: Double?
}

struct CSwapUsage: Decodable, Sendable {
    let fiveHour: CSwapMeter?
    let sevenDay: CSwapMeter?
    let scoped: [CSwapMeter]?
}

struct CSwapMeter: Decodable, Sendable {
    let pct: Double?
    let resetsAt: String?
    let countdown: String?
    let clock: String?
    let name: String?          // present on scoped meters only
}

// ISO8601 with fractional seconds and offset; retry without fractional on
// failure. Fresh formatter instances per call — no shared mutable statics.
enum ResetsAtParser {
    static func parse(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFractional.date(from: raw) {
            return date
        }
        let withoutFractional = ISO8601DateFormatter()
        withoutFractional.formatOptions = [.withInternetDateTime]
        return withoutFractional.date(from: raw)
    }
}

/// Shared "2d 16h" / "3h 30m" / "12m" formatting — computed live from a
/// `resetsAt` date, never from cswap's cached countdown string. One
/// implementation for the footer, the account row's countdown line, and
/// anywhere else a reset needs to read as relative time.
enum Countdown {
    static func string(until resetsAt: Date, now: Date) -> String {
        let seconds = max(0, resetsAt.timeIntervalSince(now))
        let totalMinutes = Int(seconds / 60)
        let days = totalMinutes / (60 * 24)
        let hours = (totalMinutes / 60) % 24
        let minutes = totalMinutes % 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }
}

// Wire → view-model: usage ?? lastGoodUsage → isStale; meters ordered 5h,
// 7d, then scoped (sorted by name).
extension MeterVM {
    init(accountNumber: Int, label: String, wire: CSwapMeter) {
        let clampedPct = min(max(wire.pct ?? 0, 0), 100)
        self.init(
            id: "\(accountNumber)-\(label)",
            label: label,
            pct: clampedPct,
            resetsAt: ResetsAtParser.parse(wire.resetsAt)
        )
    }
}

extension AccountVM {
    /// Returns nil when the account has no usable slot number — cswap always
    /// sends one, but every leaf is optional per spec, so we guard it.
    init?(wire: CSwapAccount) {
        guard let number = wire.number else { return nil }
        let email = wire.email ?? ""

        let displayName: String
        if let alias = wire.alias, !alias.isEmpty {
            displayName = alias
        } else if let atIndex = email.firstIndex(of: "@") {
            displayName = String(email[email.startIndex..<atIndex])
        } else {
            displayName = email
        }

        let effectiveUsage = wire.usage ?? wire.lastGoodUsage

        var meters: [MeterVM] = []
        if let fiveHour = effectiveUsage?.fiveHour {
            meters.append(MeterVM(accountNumber: number, label: "5h", wire: fiveHour))
        }
        if let sevenDay = effectiveUsage?.sevenDay {
            meters.append(MeterVM(accountNumber: number, label: "7d", wire: sevenDay))
        }
        if let scoped = effectiveUsage?.scoped {
            for meter in scoped.sorted(by: { ($0.name ?? "") < ($1.name ?? "") }) {
                meters.append(MeterVM(accountNumber: number, label: meter.name ?? "?", wire: meter))
            }
        }

        self.init(
            id: number,
            displayName: displayName,
            email: email,
            isActive: wire.active ?? false,
            needsRelogin: wire.usageStatus == "relogin_required",
            isStale: wire.usage == nil,
            meters: meters
        )
    }
}
