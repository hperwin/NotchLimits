import AppKit

// `--demo-open`: launch straight into `.open`, skipping the hover dwell.
// `--pin-open`: with `--demo-open`, the panel stays open with no cursor
// near it, so screen recordings can capture it.
// `--snapshot <path>`: headless render of the open panel to a PNG, print
// SNAPSHOT OK/FAIL, exit — no window, no event loop.
// `--tokens`: headless count of every Claude Code and Codex log, print the
// totals and per-log offsets as JSON, exit.
// Default: normal hover companion.

let arguments = CommandLine.arguments.dropFirst()
var demoOpen = false
var pinOpen = false
var tokensOnly = false
var snapshotPath: String?

var iterator = arguments.makeIterator()
while let argument = iterator.next() {
    switch argument {
    case "--demo-open":
        demoOpen = true
    case "--pin-open":
        pinOpen = true
    case "--tokens":
        tokensOnly = true
    case "--snapshot":
        snapshotPath = iterator.next()
    default:
        break
    }
}

if tokensOnly {
    let tokens = TokenStore()
    await tokens.catchUp()
    print(String(decoding: tokens.summaryJSON(), as: UTF8.self))
    exit(0)
}

if let snapshotPath {
    let store = UsageStore()
    store.start()
    let ok = await Snapshot.write(store: store, to: snapshotPath)
    print(ok ? "SNAPSHOT OK" : "SNAPSHOT FAIL")
    exit(ok ? 0 : 1)
}

let app = NSApplication.shared
let delegate = AppDelegate(demoOpen: demoOpen, pinOpen: pinOpen)
app.delegate = delegate
app.run()
