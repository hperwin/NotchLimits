import Foundation
import Combine

/// Non-Sendable payload of one cswap fetch attempt, hopped back to the main
/// actor by `refreshNow()`.
private enum FetchOutcome: Sendable {
    case success(CSwapListOutput)
    case failure(String)
}

@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var accounts: [AccountVM] = []
    @Published private(set) var activeNumber: Int? = nil
    @Published private(set) var lastUpdated: Date? = nil
    @Published private(set) var fetchError: String? = nil

    // Scripts/nl-usage is an optional shim that merges `cswap list --json`
    // with OpenAI Codex rate limits, emitting the same wire schema (Codex as
    // account slot 99). Installing it at ~/.local/bin/nl-usage opts in; the
    // resolved path is fixed at process start, like the cswap path always was.
    private nonisolated static let cswapExecutablePath: String = {
        let shim = ("~/.local/bin/nl-usage" as NSString).expandingTildeInPath
        if FileManager.default.isExecutableFile(atPath: shim) {
            return shim
        }
        return ("~/.local/bin/cswap" as NSString).expandingTildeInPath
    }()
    private nonisolated static let logFilePath =
        ("~/Library/Logs/cswap-auto.log" as NSString).expandingTildeInPath

    /// Dedicated background queue for the blocking Process/Pipe work — keeps
    /// it off Swift's cooperative thread pool.
    private let fetchQueue = DispatchQueue(label: "com.hayden.notchlimits.usagefetch", qos: .utility)

    // Lifecycle plumbing only, never touched concurrently: mutated exclusively
    // from main-actor methods below, and read once in deinit after the last
    // reference to self is already gone. nonisolated(unsafe) here avoids a
    // deinit/global-actor isolation landmine without hiding a real race.
    private nonisolated(unsafe) var refreshLoopTask: Task<Void, Never>?
    private nonisolated(unsafe) var debounceTask: Task<Void, Never>?
    private nonisolated(unsafe) var logFileSource: DispatchSourceFileSystemObject?

    deinit {
        refreshLoopTask?.cancel()
        debounceTask?.cancel()
        logFileSource?.cancel()
    }

    func start() {
        refreshNow()
        refreshLoopTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                if Task.isCancelled { break }
                self?.refreshNow()
            }
        }
        watchLogFile()
    }

    func refreshNow() {
        fetchQueue.async { [weak self] in
            let outcome = UsageStore.runCSwapList()
            Task { @MainActor in
                self?.apply(outcome)
            }
        }
    }

    private func apply(_ outcome: FetchOutcome) {
        switch outcome {
        case .success(let output):
            var mapped = (output.accounts ?? [])
                .compactMap(AccountVM.init(wire:))
                .sorted { $0.id < $1.id }
            // Two accounts can share an email local-part (e.g. x@gmail.com
            // and x@proton.me) — disambiguate colliding names with the
            // domain's first label so every row is identifiable.
            let collisions = Dictionary(grouping: mapped, by: \.displayName)
                .filter { $0.value.count > 1 }.keys
            for i in mapped.indices where collisions.contains(mapped[i].displayName) {
                let domain = mapped[i].email.split(separator: "@").last ?? ""
                let host = domain.split(separator: ".").first ?? domain
                mapped[i].displayName += " (\(host))"
            }
            accounts = mapped
            activeNumber = output.activeAccountNumber
            fetchError = nil
            lastUpdated = Date()
        case .failure(let message):
            // Never blank the panel — keep whatever accounts/lastUpdated we had.
            fetchError = message
        }
    }

    // MARK: - Daemon log watch (instant refresh on switch/poll events)

    private func watchLogFile() {
        let fd = open(Self.logFilePath, O_EVTONLY)
        guard fd >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .rename, .delete],
            queue: fetchQueue
        )
        // A plain closure here would silently infer this method's MainActor
        // isolation, then trap (EXC_BREAKPOINT) when GCD actually invokes it
        // on `fetchQueue`. Typing it `@Sendable` keeps it queue-agnostic;
        // the real hop to MainActor happens via the Task below.
        let handler: @Sendable () -> Void = { [weak self] in
            Task { @MainActor in
                self?.scheduleDebouncedRefresh()
            }
        }
        source.setEventHandler(handler: handler)
        source.setCancelHandler {
            close(fd)
        }
        source.resume()
        logFileSource = source
    }

    private func scheduleDebouncedRefresh() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            self?.refreshNow()
        }
    }

    // MARK: - cswap process (background queue; runs off the main actor)

    /// stdout may carry a leading upgrade-notice line before the JSON payload
    /// — decode from the first '{' onward. 10s kill timeout via a watchdog
    /// that terminates the process without blocking the read.
    private nonisolated static func runCSwapList() -> FetchOutcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cswapExecutablePath)
        process.arguments = ["list", "--json"]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            return .failure("cswap failed to launch: \(error.localizedDescription)")
        }

        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 10) {
            if process.isRunning {
                process.terminate()
            }
        }

        let outputData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard let rawOutput = String(data: outputData, encoding: .utf8), !rawOutput.isEmpty else {
            return .failure("cswap produced no output (exit \(process.terminationStatus))")
        }
        guard let braceIndex = rawOutput.firstIndex(of: "{") else {
            return .failure("cswap output had no JSON payload")
        }
        guard let jsonData = String(rawOutput[braceIndex...]).data(using: .utf8) else {
            return .failure("could not re-encode cswap JSON")
        }

        do {
            let decoded = try JSONDecoder().decode(CSwapListOutput.self, from: jsonData)
            return .success(decoded)
        } catch {
            return .failure("cswap JSON decode failed: \(error.localizedDescription)")
        }
    }
}
