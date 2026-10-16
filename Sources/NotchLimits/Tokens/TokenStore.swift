import Foundation
import Combine
import CoreServices

/// All-time Claude Code + Codex token totals for this Mac, updated live.
///
/// The ledger (`token-ledger.json` in the state directory) remembers, per
/// log, the byte offset already counted, the tokens those bytes produced and
/// the parser state at that offset. Logs are append-only, so catching a file
/// up reads only the bytes past its offset, a relaunch resumes exactly where
/// the last run stopped, and logs the tools prune keep their tokens forever:
/// nothing here ever subtracts.
///
/// Same shape as UsageStore: the UI talks to this main-actor object, every
/// byte of file IO happens on `Ingest`'s private serial queue, and results
/// hop back with `Task { @MainActor in }`.
@MainActor
final class TokenStore: ObservableObject {
    @Published private(set) var claude: Int64 = 0
    @Published private(set) var codex: Int64 = 0
    var total: Int64 { claude + codex }
    @Published private(set) var isCaughtUp = false

    /// The value the hero last landed on, persisted in the ledger so the next
    /// open rolls from there. Lives here because PanelContent is unmounted
    /// while the panel is closed. Never lowered, so no path (a quit mid-roll,
    /// an early mount) can start a later open below a number already seen.
    var lastShown: Int64? {
        get { shown }
        set {
            guard let newValue, newValue > shown ?? -1 else { return }
            shown = newValue
            ingest.setLastShown(newValue)
        }
    }
    private var shown: Int64?

    nonisolated static var defaultStateDirectory: URL {
        if let dir = ProcessInfo.processInfo.environment["NOTCHLIMITS_STATE_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: (dir as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NotchLimits", isDirectory: true)
    }

    private let ingest: Ingest

    init(stateDirectory: URL = TokenStore.defaultStateDirectory) {
        ingest = Ingest(ledger: stateDirectory.appendingPathComponent("token-ledger.json"))
        ingest.publish = { [weak self] totals in
            Task { @MainActor in self?.apply(totals) }
        }
    }

    deinit { ingest.stop() }

    /// Catches every log up off-main (publishing partial totals at most 4
    /// times a second, so the hero rolls up while a first run counts), then
    /// tails live. Saves itself when dirty, at most once a minute: a relaunch
    /// replays the logs exactly from the last save, so a longer gap loses
    /// nothing and spares the disk a multi-MB rewrite every few seconds.
    func start() { ingest.start() }

    /// One full catch-up to EOF with no watching and no autosave, so the
    /// headless modes stay read-only. Returns once the totals are final.
    func catchUp() async {
        let totals = await withCheckedContinuation { (done: CheckedContinuation<Totals, Never>) in
            ingest.catchUp { done.resume(returning: $0) }
        }
        apply(totals)
    }

    /// Writes the ledger now. It may wait for the file the ingest queue is
    /// reading (one slice of a catch-up), so call it at quit, not per frame.
    func save() { ingest.queue.sync { ingest.write() } }

    /// `{"claude","codex","files":{"<source>:<ledgerKey>":{"offset","path","tokens"}},"total"}`
    /// with sorted keys, from one consistent snapshot of the ledger.
    func summaryJSON() -> Data { ingest.queue.sync { ingest.summary() } }

    private func apply(_ totals: Totals) {
        // Hops can land out of order and totals only ever grow, so the
        // larger value is always the newer one.
        if totals.claude > claude { claude = totals.claude }
        if totals.codex > codex { codex = totals.codex }
        if totals.caughtUp && !isCaughtUp { isCaughtUp = true }
        if let saved = totals.lastShown, saved > shown ?? -1 { shown = saved }
    }
}

private struct Totals: Sendable {
    var claude: Int64
    var codex: Int64
    var caughtUp: Bool
    var lastShown: Int64?
}

/// One log's line in the ledger.
private struct Entry<State: Codable & Sendable>: Codable {
    var path: String
    var offset: Int64
    var tokens: Int64
    var state: State
}

private struct LedgerFile: Codable {
    var version = 1
    var lastShown: Int64?
    var claude: [String: Entry<ClaudeTokens.FileState>]
    var codex: [String: Entry<CodexTokens.FileState>]
}

private struct Summary: Encodable {
    struct File: Encodable { let path: String; let offset: Int64; let tokens: Int64 }
    let total: Int64
    let claude: Int64
    let codex: Int64
    let files: [String: File]
}

/// One source's part of the ledger, with a running sum so a live event costs
/// one addition instead of re-adding thousands of entries.
private final class Book<S: TokenSource> {
    var files: [String: Entry<S.FileState>] = [:]
    var sum: Int64 = 0
    var roots: [String] = []

    func owns(_ path: String) -> Bool {
        roots.contains { path.hasPrefix($0 + "/") } && S.isLog(URL(fileURLWithPath: path, isDirectory: false))
    }
}

/// Everything that touches files or the ledger. All mutable state is
/// confined to `queue`: the FSEvents stream, every vnode source and the slow
/// tick deliver on it, and the store only reaches in through `queue.async`/
/// `queue.sync`. That confinement is what makes `@unchecked Sendable` true.
private final class Ingest: @unchecked Sendable {
    let queue = DispatchQueue(label: "com.hayden.notchlimits.tokens", qos: .utility)
    /// Set once by TokenStore.init, before anything that publishes is queued.
    var publish: @Sendable (Totals) -> Void = { _ in }

    private let ledgerURL: URL
    private let claude = Book<ClaudeTokens>()
    private let codex = Book<CodexTokens>()
    private var lastShown: Int64?
    private var live = false, caughtUp = false, unreadable = false
    private let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: 4 << 20, alignment: 16)

    private var stream: FSEventStreamRef?
    private var streamRoots: [String] = []
    private var watchers: [String: DispatchSourceFileSystemObject] = [:]
    private var lastHeldScan: UInt64 = 0
    private var ticker: DispatchSourceTimer?

    /// Waiters of the running pass, and of the one queued behind it (a pass
    /// asked for mid-pass must start after the ask to mean "up to now").
    private var running: [@Sendable (Totals) -> Void]?
    private var queued: [@Sendable (Totals) -> Void]?

    private var dirty = false, saveArmed = false, lastSave: UInt64 = 0
    private var publishArmed = false, lastPublish: UInt64 = 0
    private var published: (Int64, Int64, Bool)?

    private static let rescan = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs
        | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged)
    private static let created = FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated)
    private static let modified = FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified)
    private static let reshaped = FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated
        | kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemRenamed)
    private static let ms: UInt64 = 1_000_000

    /// The ledger loads first: everything else is queued behind it.
    init(ledger: URL) { ledgerURL = ledger; queue.async { [self] in load() } }
    deinit { buffer.deallocate() }

    // MARK: - Entry points (any thread)

    func start() {
        queue.async { [self] in
            guard !live else { return }
            live = true
            requestPass(nil)
            let ticker = DispatchSource.makeTimerSource(queue: queue)
            ticker.schedule(deadline: .now() + 10, repeating: 10, leeway: .seconds(5))
            ticker.setEventHandler { [weak self] in self?.tick() }
            ticker.resume()
            self.ticker = ticker
        }
    }

    func catchUp(_ done: @escaping @Sendable (Totals) -> Void) {
        queue.async { [self] in requestPass(done) }
    }

    func setLastShown(_ value: Int64?) {
        queue.async { [self] in lastShown = value; markDirty() }
    }

    func stop() {
        queue.async { [self] in
            ticker?.cancel()
            stopStream()
            for path in watchers.keys { unwatch(path) }
        }
    }

    // MARK: - Ledger (queue only)

    private func load() {
        guard let data = try? Data(contentsOf: ledgerURL),
              let file = try? JSONDecoder().decode(LedgerFile.self, from: data), file.version == 1 else {
            // Missing is a first run. Present but unreadable (corrupt, or a
            // newer format) also recounts the logs on disk, but the file may
            // hold the only count of logs since pruned, so `write` sets it
            // aside instead of replacing it.
            unreadable = FileManager.default.fileExists(atPath: ledgerURL.path)
            return
        }
        claude.files = file.claude
        codex.files = file.codex
        claude.sum = file.claude.values.reduce(0) { $0 + $1.tokens }
        codex.sum = file.codex.values.reduce(0) { $0 + $1.tokens }
        lastShown = file.lastShown
    }

    func write() {
        guard dirty else { return }
        lastSave = Self.now()
        if unreadable {
            let aside = ledgerURL.deletingLastPathComponent()
                .appendingPathComponent("token-ledger.unreadable-\(Int(Date().timeIntervalSince1970)).json")
            guard rename(ledgerURL.path, aside.path) == 0 || errno == ENOENT else { return }
            unreadable = false
        }
        let file = LedgerFile(lastShown: lastShown, claude: claude.files, codex: codex.files)
        guard (try? FileManager.default.createDirectory(
                  at: ledgerURL.deletingLastPathComponent(), withIntermediateDirectories: true)) != nil,
              let data = try? JSONEncoder().encode(file),
              (try? data.write(to: ledgerURL, options: .atomic)) != nil else { return }
        dirty = false
    }

    /// Autosave only once `start()` made this the live app; `catchUp()`
    /// alone never writes. No timer exists while the ledger is clean.
    private func markDirty() {
        dirty = true
        guard live, !saveArmed else { return }
        saveArmed = true
        let wait = (lastSave + 60_000 * Self.ms).subtractingReportingOverflow(Self.now())
        queue.asyncAfter(deadline: .now() + .nanoseconds(wait.overflow ? 0 : Int(wait.partialValue))) { [self] in
            saveArmed = false
            write()
        }
    }

    func summary() -> Data {
        var files: [String: Summary.File] = [:]
        func add<S>(_ book: Book<S>) {
            for (key, entry) in book.files {
                files["\(S.id):\(key)"] = .init(path: entry.path, offset: entry.offset, tokens: entry.tokens)
            }
        }
        add(claude)
        add(codex)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let summary = Summary(total: claude.sum + codex.sum, claude: claude.sum, codex: codex.sum, files: files)
        return (try? encoder.encode(summary)) ?? Data()
    }

    // MARK: - Publishing (queue only)

    private var totals: Totals {
        Totals(claude: claude.sum, codex: codex.sum, caughtUp: caughtUp, lastShown: lastShown)
    }

    /// At most 4 Hz: publish now if the last one is 250 ms old, else once at
    /// that mark with whatever the totals are by then.
    private func publishSoon() {
        guard !publishArmed else { return }
        let wait = (lastPublish + 250 * Self.ms).subtractingReportingOverflow(Self.now())
        guard !wait.overflow, wait.partialValue > 0 else { return publishNow() }
        publishArmed = true
        queue.asyncAfter(deadline: .now() + .nanoseconds(Int(wait.partialValue))) { [self] in
            publishArmed = false
            publishNow()
        }
    }

    private func publishNow() {
        let totals = totals
        guard published.map({ $0 != (totals.claude, totals.codex, totals.caughtUp) }) ?? true else { return }
        published = (totals.claude, totals.codex, totals.caughtUp)
        lastPublish = Self.now()
        publish(totals)
    }

    // MARK: - Full catch-up (queue only)

    private func requestPass(_ done: (@Sendable (Totals) -> Void)?) {
        let waiters = done.map { [$0] } ?? []
        if running != nil {
            queued = (queued ?? []) + waiters
            return
        }
        running = waiters
        beginPass()
    }

    private func beginPass() {
        claude.roots = ClaudeTokens.roots().map(\.path)
        codex.roots = CodexTokens.roots().map(\.path)
        // The stream starts before the walk, so a line written to a file
        // after its catch-up but before the walk ends is still heard. Roots
        // are only ever added: a root that vanished stays watched (FSEvents
        // watches a missing path fine), so its return is heard too.
        let watched = Set(streamRoots).union(claude.roots + codex.roots)
        if live && watched.count != streamRoots.count { restartStream(watched.sorted()) }
        var todo: [String] = []
        enumerate(claude, into: &todo)
        enumerate(codex, into: &todo)
        step(todo[...])
    }

    private func enumerate<S>(_ book: Book<S>, into todo: inout [String]) {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey]
        for root in book.roots {
            guard let walker = FileManager.default.enumerator(
                at: URL(fileURLWithPath: root, isDirectory: true), includingPropertiesForKeys: Array(keys)) else { continue }
            for case let url as URL in walker {
                guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true,
                      S.isLog(url) else { continue }
                // A relaunch stats ~5,000 logs and opens only the ones that grew.
                if let entry = book.files[S.ledgerKey(for: url)], entry.path == url.path,
                   entry.offset == Int64(values.fileSize ?? -1) { continue }
                todo.append(url.path)
            }
        }
    }

    /// Works in 50 ms slices that re-queue themselves, so a first run's
    /// multi-GB backfill never holds the queue: live events, partial
    /// publishes and `save()` all get in between slices.
    private func step(_ todo: ArraySlice<String>) {
        let deadline = Self.now() + 50 * Self.ms
        var rest = todo
        while let path = rest.first, Self.now() < deadline {
            guard tail(path, until: deadline) else { break }
            rest = rest.dropFirst()
        }
        publishSoon()
        if !rest.isEmpty {
            queue.async { [self, rest] in step(rest) }
            return
        }
        caughtUp = true
        if live { reconcileWatchers() }
        publishSoon()
        let finished = running ?? []
        running = nil
        finished.forEach { $0(totals) }
        if let next = queued {
            queued = nil
            running = next
            beginPass()
        }
    }

    // MARK: - Tailing one log (queue only)

    /// Returns false only when `deadline` stopped it mid-file.
    @discardableResult
    private func tail(_ path: String, until deadline: UInt64 = .max) -> Bool {
        if claude.owns(path) { return tail(claude, path, deadline) }
        if codex.owns(path) { return tail(codex, path, deadline) }
        return true
    }

    private func tail<S>(_ book: Book<S>, _ path: String, _ deadline: UInt64) -> Bool {
        let key = S.ledgerKey(for: URL(fileURLWithPath: path, isDirectory: false))
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return true }   // deleted: its tokens stay counted
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return true }
        let size = Int64(info.st_size)
        let known = book.files[key]
        // A key seen at a new path is the same log moved (Codex archives a
        // rollout by renaming it): adopt the path, keep offset and tokens.
        // While the old path still exists the newcomer is a copy, and
        // reading both against one offset would count lines twice.
        if let known, known.path != path, access(known.path, F_OK) == 0 { return true }
        var entry = known ?? Entry(path: path, offset: 0, tokens: 0, state: S.newState())
        entry.path = path
        // Shorter than its offset, or no newline right before it: the file
        // was rewritten. Its old lines were counted and may well reappear, so
        // recount from byte 0 but credit only what exceeds the tokens it
        // already had. The total never drops and rewritten history never
        // counts twice; lines appended after this pass count normally.
        var previous: UInt8 = 10
        let rewritten = entry.offset > size
            || (entry.offset > 0 && pread(fd, &previous, 1, off_t(entry.offset - 1)) == 1 && previous != 10)
        let counted = entry.tokens
        if rewritten { entry = Entry(path: path, offset: 0, tokens: 0, state: S.newState()) }

        // Large reads, complete lines only. The offset commits after the last
        // newline, so a half-written line waits for the event that ends it.
        let base = buffer.baseAddress!
        var position = entry.offset, line = Data(), finished = true
        while position < size {
            let n = pread(fd, base, min(buffer.count, Int(size - position)), off_t(position))
            guard n > 0 else { break }
            var start = 0
            while let hit = memchr(base + start, 10, n - start) {
                let end = UnsafeRawPointer(base).distance(to: UnsafeRawPointer(hit))
                line.append(base.assumingMemoryBound(to: UInt8.self) + start, count: end - start)
                entry.tokens += max(0, S.consume(line, state: &entry.state))
                line.removeAll(keepingCapacity: true)
                entry.offset = position + Int64(end + 1)
                start = end + 1
            }
            line.append(base.assumingMemoryBound(to: UInt8.self) + start, count: n - start)
            position += Int64(n)
            if !rewritten, position < size, Self.now() >= deadline { finished = false; break }
        }
        if rewritten { entry.tokens = max(entry.tokens, counted) }

        guard known == nil || rewritten || entry.offset != known?.offset || path != known?.path
        else { return finished }
        book.sum += entry.tokens - counted
        book.files[key] = entry
        markDirty()
        return finished
    }

    // MARK: - Live tail (queue only)

    private func restartStream(_ roots: [String]) {
        stopStream()
        streamRoots = roots
        guard !streamRoots.isEmpty else { return }
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        // NoDefer delivers a lone event at once and batches only what follows
        // within the 0.3 s latency: a quiet append lands in ~12 ms (p95 22)
        // instead of up to 0.3 s (p95 315), at the same callback rate.
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes
            | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagNoDefer)
        guard let created = FSEventStreamCreate(
            nil, fsEventsCallback, &context, streamRoots as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3, flags) else { return }
        FSEventStreamSetDispatchQueue(created, queue)
        FSEventStreamStart(created)
        stream = created
    }

    private func stopStream() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    fileprivate func handle(_ paths: [String], _ flags: [FSEventStreamEventFlags]) {
        for (path, flag) in zip(paths, flags) {
            // Dropped events, or a root itself created, moved or deleted:
            // walk everything again.
            if flag & Self.rescan != 0 || (flag & Self.reshaped != 0 && streamRoots.contains(path)) {
                requestPass(nil)
                continue
            }
            guard claude.owns(path) || codex.owns(path) else { continue }
            // Modified means a writer closed the file after writing, so this
            // stream hears that writer by itself. Created without it means a
            // writer may be holding the new file open: watch it per append.
            if flag & Self.modified != 0 { unwatch(path) } else if flag & Self.created != 0 { watch(path) }
            tail(path)
        }
        if Self.now() - lastHeldScan > 5_000 * Self.ms { reconcileWatchers() }
        publishSoon()
    }

    /// The live phase's own slow clock, for the two changes that post no
    /// FSEvents: a log root created after launch (a first Codex run, a new
    /// profile or sandbox) and a writer that reopens an existing log and holds
    /// it (Codex resuming a thread). A tick is the root globs plus one
    /// process-table scan, about 30 ms of background CPU with a thousand
    /// processes running, and the leeway lets the system fold it into other
    /// wakeups.
    private func tick() {
        guard running == nil else { return }   // a pass reconciles as it ends
        if ClaudeTokens.roots().map(\.path) != claude.roots || CodexTokens.roots().map(\.path) != codex.roots {
            return requestPass(nil)
        }
        reconcileWatchers()
        publishSoon()
    }

    /// FSEvents hears about a write only when the writer closes the file, and
    /// Codex keeps each rollout open for its whole session. So every log some
    /// process holds open for writing also gets a kqueue watcher, which fires
    /// per append and costs nothing while the file is quiet. Run after each
    /// full catch-up, on every tick, and at most every 5 s while FSEvents
    /// reports activity.
    private func reconcileWatchers() {
        lastHeldScan = Self.now()
        let held = Self.openForWriting().filter { claude.owns($0) || codex.owns($0) }
        for path in watchers.keys where !held.contains(path) { unwatch(path) }
        for path in held where watchers[path] == nil {
            watch(path)
            tail(path)
        }
    }

    private func watch(_ path: String) {
        guard watchers[path] == nil else { return }
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename], queue: queue)
        source.setEventHandler { [weak self, weak source] in
            guard let self, let source else { return }
            // Gone from this path: FSEvents reports where it went.
            if !source.data.isDisjoint(with: [.delete, .rename]) { self.unwatch(path) }
            self.tail(path)
            self.publishSoon()
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        watchers[path] = source
    }

    private func unwatch(_ path: String) {
        watchers.removeValue(forKey: path)?.cancel()
    }

    // MARK: - Helpers

    private static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

    /// Paths of files any process this user can inspect holds open for
    /// writing. One pass over the process table: 5 to 20 ms with a thousand
    /// processes running.
    private static func openForWriting() -> Set<String> {
        var pids = [pid_t](repeating: 0, count: Int(proc_listallpids(nil, 0)) + 64)
        let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        var paths = Set<String>()
        for pid in pids.prefix(max(0, count)) {
            let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
            guard bytes > 0 else { continue }
            var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / MemoryLayout<proc_fdinfo>.stride)
            let listed = Int(proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, bytes)) / MemoryLayout<proc_fdinfo>.stride
            for fd in fds.prefix(max(0, listed)) where fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
                var vnode = vnode_fdinfowithpath()
                let size = Int32(MemoryLayout<vnode_fdinfowithpath>.stride)
                guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &vnode, size) == size,
                      vnode.pfi.fi_openflags & UInt32(FWRITE) != 0 else { continue }
                paths.insert(withUnsafeBytes(of: vnode.pvip.vip_path) {
                    String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self)
                })
            }
        }
        return paths
    }
}

private let fsEventsCallback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
    guard let info else { return }
    let ingest = Unmanaged<Ingest>.fromOpaque(info).takeUnretainedValue()
    let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
    ingest.handle(list, Array(UnsafeBufferPointer(start: flags, count: count)))
}
